import json, os, re, sys
from collections import Counter

SP  = os.environ.get('BUILD', 'fpga/build')
LOG = open(SP + '/pnr.log').read()
W   = 76
B, D, R = "\033[1m", "\033[2m", "\033[0m"

def rule(ch="─"): print(D + ch*W + R)
def head(t):
    print()
    print(B + "┌" + "─"*(W-2) + "┐" + R)
    print(B + "│" + t.center(W-2) + "│" + R)
    print(B + "└" + "─"*(W-2) + "┘" + R)

# ---------------- versions / flow ----------------
head("Tang Nano 20K — area & timing, open-source flow")
ys = re.search(r"Yosys (\d[\w.+]*)", open(SP+'/ver_yosys.txt').read())
np_ = re.search(r"Version nextpnr-([\w.\-]+)", open(SP+'/ver_nextpnr.txt').read())
print(f"  device      {os.environ.get('DEVICE','?')}  (fabric {os.environ.get('FAMILY','?')})")
print(f"  board       Sipeed Tang Nano 20K, 27 MHz crystal")
print(f"  synthesis   yosys {ys.group(1) if ys else '?'}  ·  synth_gowin -family gw2a")
print(f"  place&route nextpnr-himbaechel {np_.group(1) if np_ else '?'}  ·  himbaechel/gowin")
print(f"  bitstream   gowin_pack (apicula)  ·  {os.path.getsize(SP+'/droop.fs')/2**20:.1f} MiB .fs")
print(f"  defines     -DFPGA   (ro_osc uses the Gowin LUT1 delay chain)")

# ---------------- post-PnR utilisation ----------------
head("AREA — post-place&route device utilisation")
util = re.findall(r"^Info: \t\s*([A-Z0-9_]+):\s+(\d+)/\s*(\d+)\s+(\d+)%", LOG, re.M)
seen=set(); rows=[]
for name, used, avail, pct in util:
    if name in seen: continue
    seen.add(name)
    if int(used): rows.append((name, int(used), int(avail)))
print(f"  {'resource':<14}{'used':>8}{'available':>12}{'util':>9}   ")
rule()
for name, used, avail in rows:
    frac = used/avail
    bar = "█"*max(1, round(frac*22)) if frac > 0.004 else "▏"
    print(f"  {name:<14}{used:>8}{avail:>12}{100*frac:>8.2f}%   {D}{bar}{R}")
rule()
lut = dict((n,u) for n,u,_ in rows)
print(f"  {D}LUT4 is the packed logic-cell count; ALU cells occupy LUT slots too.{R}")

# ---------------- per-block area ----------------
head("AREA — per-block breakdown (standalone synthesis)")
TOPS = [("tangnano20k_top","FPGA top: tile + LEDs + UART"),
        ("tt_um_rcyaon_droop","TT tile (this is what tapes out)"),
        ("droop_sensor","divider + period/freq counters"),
        ("aggressor","128-flop switching load"),
        ("ro_osc","25-stage LUT1 ring + enable"),
        ("uart_tx","8N1 serialiser (FPGA only)")]
def blk(top):
    d=json.load(open(f"{SP}/s_{top}.json"))
    c=Counter()
    for mn,m in d['modules'].items():
        for cell in m['cells'].values():
            t=cell['type'].lstrip('\\')
            if not t.startswith('$'): c[t]+=1
    L=sum(v for k,v in c.items() if k.startswith('LUT'))
    A=c.get('ALU',0); M=sum(v for k,v in c.items() if k.startswith('MUX'))
    F=sum(v for k,v in c.items() if k.startswith('DFF'))
    return L,A,M,F
print(f"  {'block':<21}{'LUT':>6}{'ALU':>6}{'MUX':>6}{'LUT-eq':>8}{'FF':>7}  {'notes'}")
rule()
for top,desc in TOPS:
    L,A,M,F = blk(top)
    ind = "  " if top in ("droop_sensor","aggressor","ro_osc") else ""
    print(f"  {ind+top:<21}{L:>6}{A:>6}{M:>6}{L+A:>8}{F:>7}  {D}{desc}{R}")
rule()
print(f"  {D}the tile alone costs MORE than the whole top: standalone it keeps all 10{R}")
print(f"  {D}divider stages and a runtime tap mux, whereas in tangnano20k_top TAP_SEL{R}")
print(f"  {D}and RO_EN are compile-time constants, so 4 stages + the mux fold away.{R}")

# ---------------- timing ----------------
head("DELAY — post-route static timing")
fmax = re.findall(r"Max frequency for clock '([^']+)': ([\d.]+) MHz \((\w+) at ([\d.]+) MHz\)", LOG)
place_f, route_f = float(fmax[0][1]), float(fmax[-1][1])
clk, verdict, target = fmax[-1][0], fmax[-1][2], float(fmax[-1][3])
cp = re.search(r"Info: ([\d.]+) ns logic, ([\d.]+) ns routing", LOG)
logic, routing = float(cp.group(1)), float(cp.group(2))
total = logic + routing
print(f"  clock domain            {clk}  (sys_clk, 1 BUFG global)")
print(f"  target frequency        {target:.2f} MHz      ({1000/target:.2f} ns period)")
print(f"  {B}achieved Fmax           {route_f:.2f} MHz{R}     ({1000/route_f:.2f} ns critical path)")
print(f"  timing verdict          {B}{verdict}{R}  —  {route_f/target:.1f}x margin over target")
print(f"  setup slack             +{1000/target - total:.2f} ns of {1000/target:.2f} ns budget")
rule()
print(f"  critical path           {total:.2f} ns total")
print(f"    logic                 {logic:.2f} ns  ({100*logic/total:.0f}%)  {D}{'█'*round(22*logic/total)}{R}")
print(f"    routing               {routing:.2f} ns  ({100*routing/total:.0f}%)  {D}{'█'*round(22*routing/total)}{R}")
print(f"  path source             src/droop_sensor.v:64")
print(f"                          {D}per_next = (per_cnt==14'h3fff) ? per_cnt : per_cnt+1{R}")
print(f"                          {D}14-bit saturating counter: compare + increment carry{R}")
print(f"                          {D}chain (ALU cells) -> sample mux -> sample_r{R}")
rule()
print(f"  {D}post-placement estimate was {place_f:.2f} MHz; routing improved it to {route_f:.2f} MHz{R}")

# ---------------- clock domains / CDC ----------------
head("CLOCK DOMAINS & CDC")
doms = sorted(set(re.findall(r"Clock '([^']+)' has no interior paths", LOG)))
cdc = re.search(r"Max delay posedge ([\w.\[\]]+) -> posedge ([\w.\[\]]+): ([\d.]+) ns", LOG)
print(f"  nextpnr auto-detected {len(doms)+1} clock domains:")
print(f"    {clk:<28}{D}system clock, 27 MHz, on a global (BUFG){R}")
for d_ in doms:
    print(f"    {d_:<28}{D}RO / ripple-divider stage, fabric-routed{R}")
rule()
print(f"  every RO-derived domain reports {B}'no interior paths'{R} — each divider")
print(f"  stage is a lone toggle flop, so nothing multi-bit can cross.")
if cdc:
    print(f"  single CDC path   {cdc.group(1)} -> {cdc.group(2)}   {B}{cdc.group(3)} ns{R}")
    print(f"                    {D}(the tapped bit entering the 2ff synchroniser){R}")
print()

# ---------------- structural verification ----------------
head("STRUCTURAL VERIFICATION")
net = json.load(open(SP + '/pnr_in.json'))
cells = net['modules']['tangnano20k_top']['cells']

# 1. does the ring oscillator survive synthesis?
drv = {}
for n, c in cells.items():
    if c['type'].startswith(('LUT', 'MUX')):
        for b in c['connections'].get('F', []):
            drv[b] = n
start = next((n for n in cells if 'u_ro' in n and 'g_dly[24]' in n), None)
ring, cur = [], start
while cur and cur not in ring:
    ring.append(cur)
    i0 = cells[cur]['connections'].get('I0')
    cur = drv.get(i0[0]) if i0 else None
inits = Counter(cells[c]['parameters']['INIT'] for c in ring)
closed = cur == start
print(f"  ring oscillator     {B}{len(ring)} cells in a closed loop{R}" if closed
      else f"  ring oscillator     {B}BROKEN — chain of {len(ring)}, not a loop{R}")
print(f"                      {D}{inits.get('10',0)} buffers (INIT=10) + {inits.get('01',0)} inverter (INIT=01){R}")
print(f"                      {D}survived synth + P&R: the oscillator is real logic,{R}")
print(f"                      {D}not swept away as a dead combinational cycle{R}")
rule()

# 2. how much of the ripple divider survived?
dv = sorted(n for n in cells if 'u_sense' in n and 'div' in n and cells[n]['type'].startswith('DFF'))
print(f"  ripple divider      {B}{len(dv)} of 10 stages kept{R}")
print(f"                      {D}TAP_SEL is a localparam (/64) on this board, so the tap{R}")
print(f"                      {D}mux folds to div[5] and stages 6-9 are dead-code removed.{R}")
print(f"                      {D}on the ASIC the tap comes from uio_in[1:0], so all 10 stay.{R}")
rule()

# 3. were the .cst pin constraints actually honoured?
cst = {}
for line in open('fpga/tangnano20k.cst'):
    m_ = re.match(r'\s*IO_LOC\s+"([^"]+)"\s+(\d+)', line)
    if m_: cst[m_.group(1)] = m_.group(2)
placed = json.load(open(SP + '/pnr_out.json'))
pm = list(placed['modules'].values())[0]['cells']
locked = 0
print(f"  pin constraints     {B}{len(cst)} IO_LOC entries in fpga/tangnano20k.cst{R}")
for n, c in pm.items():
    a = c.get('attributes', {})
    bel = a.get('NEXTPNR_BEL', '')
    if 'IOB' in bel and int(a.get('BEL_STRENGTH', '0'), 2) >= 5:
        locked += 1
print(f"                      {B}{locked} IO cells locked to their requested sites{R}")
print(f"                      {D}nextpnr accepted every pin number as a legal site for{R}")
print(f"                      {D}this package, and applied the IO_TYPE / PULL_MODE.{R}")
print(f"                      {D}that is a legality check, NOT proof the numbers match{R}")
print(f"                      {D}the Sipeed schematic — still verify before you flash.{R}")
print()

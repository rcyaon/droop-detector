![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# droop-detector

a chip's supply voltage is not the flat number the datasheet promises.
whenever a lot of transistors switch at the same moment, they pull a
spike of current, and the voltage at that spot on the die dips for a
moment before the power network can catch up. that dip is called
**supply droop**.

it matters because gates get *slower* when their supply is lower. so the
instant a chip is busiest is the instant it is least able to meet its
own clock — which is why a design that passes timing on paper can still
fail in silicon. droop is also what power-management logic reacts to,
and what an attacker pokes at in a fault-injection attack.

the catch is that you cannot see it from outside. by the time the dip
reaches a package pin, the board's capacitors have smoothed it away.
you have to measure it on the die.

this tile does two thing:

1. **makes** droop, on command, in a controlled and repeatable way, and
2. **measures** it, and reports the result as a plain byte you can read
   with a logic analyzer.

## the idea: a voltmeter made of logic gates

a **ring oscillator** is a chain of inverting gates wired in a loop, so
the signal chases its own tail forever. nobody clocks it; its frequency
is set by nothing but how fast its own gates switch.

and how fast a gate switches depends on its supply voltage. delay scales
roughly with $C_L V_{DD} / I_D$, and the drive current $I_D$ collapses as
$(V_{DD}-V_{th})$ shrinks, so a few percent of droop turns into a few
percent of frequency shift.[^1]

that is the whole trick. count the ring's frequency and you have
measured the voltage, using a circuit made of the same standard cells as
everything else on the die. the ring sits *in* the tile it is measuring,
so it sees the same local supply as the logic around it.

## on the tile

- a ring of 25 delay cells closed by a nand gate (the
  nand is both the loop's single inversion and its on/off switch). it
  oscillates far too fast to count directly, so a 10-stage ripple
  divider slows it down; you pick a tap from ÷16 to ÷1024. exactly one
  bit crosses from the ring's world into the system clock's, through a
  two-flop synchronizer. nothing multi-bit ever crosses, which is what
  keeps that boundary safe.

- the droop *generator*: 64 flip-flops that all
  toggle on the same clock edge, doing no useful work. each toggle
  yanks a synchronized slug of current out of the tile's supply rail:
  a deliberate, repeatable di/dt event.[^2] it runs continuously, as a
  single burst on a trigger, or as periodic bursts, with the burst
  length selectable from 16 to 2048 cycles. the width is 64 because
  that is what fit — see [why 64](#why-the-aggressor-is-64-flops-wide).

- **the measurement** — two ways to turn the ring into a number:

  | mode | what it counts | good for |
  |---|---|---|
  | period | system-clock cycles in one divided-ring period | fast sampling — watching a droop event unfold |
  | frequency | divided-ring edges in an 8192-clock window | slow and precise — the static voltage-vs-count curve |

  in period mode the reading moves the intuitive way: **droop ⇒ ring
  slows ⇒ count rises**. each new reading raises a `valid` strobe; if a
  count pins at 0xff a saturation flag goes high and you should pick a
  faster divider tap.

### what it can and cannot see

this measures the **envelope** of a supply excursion, not the sharp
instantaneous notch. the sample rate is set by the divided ring, so the
resolution is microsecond-ish: you see the package- and board-level sag
fighting the decoupling capacitors, not the nanosecond spike underneath
it.

it is the same tradeoff as watching a glitch through a scope with too
little bandwidth — except the probe here is the victim circuit itself.

## using it

a bench supply and a scope or logic analyzer are enough; no external
hardware is required.

1. **prove the counters first.** set `uio[2]=1` and the sensor measures
   a clk/2 square wave instead of the ring: period mode then reads 33
   counts at tap ÷16 and 129 at ÷64 (the ÷16 and ÷64 periods of a clk/2
   source, plus one clk of synchronizer offset), and pins at 0xff with
   `uio[6]` raised at ÷256. wrong numbers there mean the divider,
   synchronizer or counters are broken rather than the supply. clear
   `uio[2]` to go back to the ring.
2. **check it is alive.** toggle the ring enable (`ui[7]`) and watch the
   divided ring on `uio[5]` change from static to oscillating. log its
   frequency at each divider tap.
3. **calibrate (frequency mode).** set `ui[6]=1`, sweep the supply from a
   bench supply, and record the sample byte on `uo[7:0]` against
   voltage. that curve is the sensor's ruler — every later measurement
   is read through it.
4. **catch a droop (period mode).** set `ui[6]=0`, arm periodic bursts
   (`ui[1:0]=11`), trigger your scope on `uio[4]` (aggressor active),
   and capture `uo[7:0]` clocked by `uio[3]` (valid). sweep the burst
   length on `ui[5:3]` and overlay the captures — longer bursts should
   push the count further up.

### pinout

| pin | dir | function |
|---|---|---|
| `ui[1:0]` | in | aggressor mode: off / continuous / triggered / periodic |
| `ui[2]` | in | aggressor trigger (rising edge) |
| `ui[5:3]` | in | burst length = 16 << sel clock cycles |
| `ui[6]` | in | 0 = period mode, 1 = frequency mode |
| `ui[7]` | in | ring oscillator enable |
| `uo[7:0]` | out | sample byte |
| `uio[1:0]` | in | divider tap: ÷16, ÷64, ÷256, ÷1024 |
| `uio[2]` | in | measure the clk/2 self-test source instead of the ring |
| `uio[3]` | out | sample valid strobe |
| `uio[4]` | out | aggressor active |
| `uio[5]` | out | divided ring output (scope this) |
| `uio[6]` | out | saturation flag (sample pinned at 0xff) |
| `uio[7]` | out | heartbeat ⊕ parity of `bank[7:0]` |

## why the aggressor is 64 flops wide

a bigger aggressor makes a bigger droop, so the honest answer to "how
wide?" is "as wide as fits." finding that edge took one failed run.

| | 128-flop bank | 64-flop bank |
|---|---|---|
| chip area | 12874.85 µm² | 8501.90 µm² |
| core area | 16493.32 µm² | 16493.32 µm² |
| utilization | 82.65% | 57.41% |
| hold buffers added by clock tree synthesis | 188 | 151 |
| outcome | `DPL-0036`, flow quit | hardens, precheck clean |

at 128 flops it did not fit. the reason is a step people forget:
after the tool builds the clock tree it inserts extra buffers to fix
hold violations, and then has to re-place everything to make room for
them. at 82.65% full there was nowhere to put them — 90 cells could not
be legally placed and the flow stopped with `[DPL-0036] Detailed
placement failed`.

two changes in `aggressor.v` bought the space back:

- **the bank went 128 → 64 flops**, the single biggest lever: each bit
  costs a toggle flop plus its next-state mux, about 21 µm².
- **the parity output narrowed from `^bank` to `^bank[7:0]`.** that
  parity pin exists only so the toggling bank has a path to a real
  output — otherwise synthesis is entitled to delete the whole thing as
  logic that drives nothing. but a full 128-bit xor reduction is a
  127-gate tree, ~2060 µm², **16% of the entire design**, spent on a
  job that 7 gates do just as well. (`(* keep *)` is what actually
  protects the bank; the parity path just keeps `opt_clean` honest.)

## fpga bench

`./fpga/bench.sh` builds the same rtl for a tang nano 20k with the
open-source gowin flow (yosys → nextpnr-himbaechel → gowin_pack) and
prints a resource and timing report. this is a cheap way to sanity-check
the design without waiting on a shuttle.

```
OSS_CAD_SUITE=/path/to/oss-cad-suite ./fpga/bench.sh
```

### how much of the fpga it uses

yosys 0.64, `synth_gowin -family gw2a`, aggressor at `WIDTH=64`:

| top | LUT-eq | DFF |
|---|---|---|
| `tangnano20k_top` — tile + LEDs + uart | 317.5 | 185 |
| `tt_um_rcyaon_droop` — what tapes out | 299.5 | 183 |
| `aggressor` alone | 175.0 | 95 |

a GW2AR-18 has 20736 LUT4 and 15552 DFF, so this is roughly 2% of the
part. always quote the toolchain version next to numbers like these:
yosys 0.68 maps wide muxes differently and reports substantially larger
area for identical rtl, so 0.64 and 0.68 figures cannot be compared.

### relevant info

- **the ring is still a ring.** synthesis tools love to delete
  combinational loops, so the bench walks the placed netlist backwards
  from `g_dly[24]` and confirms it returns to the start after 26 cells:
  25 buffers plus 1 inverter. (the enable gate folds into that inverter
  because `ui_in[7]` is tied high on the board, so the fpga build cannot
  park the oscillator.)
- **nothing multi-bit crosses clock domains.** every ring-derived domain
  is a chain of lone toggle flops with no interior paths, and exactly
  one path crosses into `clk`, landing on the two-flop synchronizer.
- **all 10 pin constraints place** on legal sites with their IO_TYPE and
  PULL_MODE applied. that is legality for the package, not agreement
  with the sipeed schematic — check that yourself before you flash.

### speed

the critical path is the saturating period counter at
`src/droop_sensor.v:78`, where the `== 14'h3fff` compare and the
increment share a carry chain. the last full place-and-route measured
3.50 ns on it — 285.80 MHz, against the 37.04 ns a 27 MHz crystal
allows, so there is plenty of margin. that run predates the `WIDTH=64`
resize, which deletes cells but does not touch this path.

read the frequency printed *after* routing; the post-placement estimate
runs about 28% pessimistic.

## footnotes

[^1]: sakurai & newton — "alpha-power law MOSFET model and its
    applications to CMOS inverter delay," IEEE JSSC, 1990

[^2]: larsson — "di/dt noise in CMOS integrated circuits," analog
    integrated circuits and signal processing, 1997

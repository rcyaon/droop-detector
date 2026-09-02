![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# droop-detector

all-digital supply droop detector on the tt sky26c shuttle. 1x1 tile, no
analog pins.

## how it works

a ring oscillator's frequency is a strong function of its local supply:
gate delay scales roughly with $C_L V_{DD} / I_D$, and $I_D$ collapses as
$(V_{DD}-V_{th})$ shrinks, so a few percent of droop shows up as a few
percent of frequency shift.[^1] the tile carries three pieces:

- **sensor**: a nand-enabled ring of 25 `dlygate4sd3` cells feeding a
  10-stage async ripple divider. one tapped bit (÷16 … ÷1024) crosses
  into the system clock domain through a 2ff synchronizer; nothing
  multi-bit ever crosses.
- **aggressor**: 128 flops toggling on the same clk edge, in continuous /
  single-burst / periodic-burst modes. every toggle pulls a synchronized
  slug of dynamic current through the tile's rail: a controlled,
  repeatable di/dt event.[^2]
- **measurement**: period mode counts clk cycles per divided-RO period
  (fast sampling: droop ⇒ RO slows ⇒ count **rises**). frequency mode
  counts divided-RO edges in an 8192-clk window (slow, high resolution,
  for the static transfer curve).

what this measures: the *envelope* of the supply excursion at
µs-ish timescales set by the divided-RO sample rate (package/board-level
sag against the decoupling network) not the ns-scale instantaneous
notch. same tradeoff as sampling droop through a scope with limited
bandwidth, except the probe is the victim circuit itself.

## fpga bench (area + delay)

`./fpga/bench.sh` builds the design for the tang nano 20k with the
open-source gowin flow and prints how much of the fpga it uses and how
fast it can run.

```
OSS_CAD_SUITE=/path/to/oss-cad-suite ./fpga/bench.sh
```

### how much fits

after place-and-route on the GW2AR-LV18QN88C8/I7:

| resource | used | avail | util |
|---|---|---|---|
| LUT4 | 578 | 20736 | 2.79% |
| DFF | 249 | 15552 | 1.60% |
| ALU | 106 | 15552 | 0.68% |
| MUX2_LUT5…8 | 179 | — | <1% |
| IOB | 10 | 384 | 2.60% |
| BUFG | 1 | 24 | 4.17% |

### how fast

**285.80 MHz**, against a 27 MHz crystal, so there is a lot of margin.
the slowest path takes 3.50 ns (1.91 ns in logic, 1.59 ns in routing)
out of the 37.04 ns a 27 MHz clock gives you.

that path is the saturating period counter at `src/droop_sensor.v:64`,
where the `== 14'h3fff` compare and the increment share a carry chain.

quote the number printed *after* routing. the earlier post-placement
estimate said 206.61 MHz, which is 28% too pessimistic.

however, three sanity checks matter more than the numbers above:

- **the ring is still a ring.** walking the netlist backwards from
  `g_dly[24]` through each input returns to the start after 26 cells: 25
  buffers (`INIT=10`) + 1 inverter (`INIT=01`). the enable gate folded
  into that inverter because `ui_in[7]` is tied high here, so the fpga
  build can't park the oscillator.
- **nothing multi-bit crosses clock domains.** nextpnr finds 7 clock
  domains on its own and reports "no interior paths" for every
  RO-derived one, because each divider stage is a lone toggle flop.
  exactly one path crosses into `clk` — 0.27 ns, landing on the 2ff
  synchronizer.
- **all 10 pins place.** every `IO_LOC` lands on a legal site with its
  IO_TYPE and PULL_MODE applied. that is legality for the package, not
  agreement with the sipeed schematic — verify that yourself before you
  flash.

### why the area numbers look inconsistent

only 6 of the 10 divider stages exist in the fpga image. `TAP_SEL` is a
localparam here, so the tap mux folds down to `div[5]` and stages 6-9
are optimized away. on the asic the tap arrives on `uio_in[1:0]` and all
10 stay. that is why the tile on its own synthesizes *larger* (731
LUT-eq) than the whole board design that contains it (562) — the gap is
what runtime tap selection costs.

area also depends on the toolchain: yosys 0.64 reports 380 LUT-eq where
0.68 reports 562, purely from how wide muxes get mapped. 

## pinout

| pin | dir | function |
|---|---|---|
| `ui[1:0]` | in | aggressor mode: off / continuous / triggered / periodic |
| `ui[2]` | in | aggressor trigger (rising edge) |
| `ui[5:3]` | in | burst length = 16 << sel clk cycles |
| `ui[6]` | in | 0 period mode / 1 frequency mode |
| `ui[7]` | in | RO enable |
| `uo[7:0]` | out | sample byte |
| `uio[1:0]` | in | divider tap: /16, /64, /256, /1024 |
| `uio[3]` | out | sample valid strobe |
| `uio[4]` | out | aggressor active |
| `uio[5]` | out | divided RO (scope this) |
| `uio[6]` | out | saturation flag |
| `uio[7]` | out | heartbeat ⊕ aggressor parity |

## footnotes

[^1]: sakurai & newton — "alpha-power law MOSFET model and its
    applications to CMOS inverter delay," IEEE JSSC, 1990

[^2]: larsson — "di/dt noise in CMOS integrated circuits," analog
    integrated circuits and signal processing, 1997

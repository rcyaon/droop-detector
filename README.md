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
- **aggressor**: 64 flops toggling on the same clk edge, in continuous /
  single-burst / periodic-burst modes. every toggle pulls a synchronized
  slug of dynamic current through the tile's rail: a controlled,
  repeatable di/dt event.[^2] the width is set by what fits: see
  [tile area](#tile-area).
- **measurement**: period mode counts clk cycles per divided-RO period
  (fast sampling: droop ⇒ RO slows ⇒ count **rises**). frequency mode
  counts divided-RO edges in an 8192-clk window (slow, high resolution,
  for the static transfer curve).

what this measures: the *envelope* of the supply excursion at
µs-ish timescales set by the divided-RO sample rate (package/board-level
sag against the decoupling network) not the ns-scale instantaneous
notch. same tradeoff as sampling droop through a scope with limited
bandwidth, except the probe is the victim circuit itself.

## tile area

the tile is 1x1, and the aggressor is what decides whether that is
possible. from the sky130 hardening flow:

| | 128-flop bank | 64-flop bank |
|---|---|---|
| chip area | 12874.85 µm² | 8501.90 µm² |
| core area | 16493.32 µm² | 16493.32 µm² |
| utilization | 82.65% | 57.41% |
| hold buffers after CTS | 188 | 151 |
| outcome | `DPL-0036`, flow quit | hardens, precheck clean |

at 128 it did not fit. openroad legalizes placement again after clock
tree synthesis adds hold buffers, and at 82.65% there was nowhere to put
them: 90 instances could not be legalized and the flow stopped with
`[DPL-0036] Detailed placement failed`.

two changes bought the space back, both in `aggressor.v`. the bank went
128 → 64 flops, the largest single lever since each bit is a toggle flop
plus its next-state mux at roughly 21 µm². and `parity` went from
`^bank` to `^bank[7:0]`: the full reduction was a WIDTH-1 gate xor tree
— 127 gates, ~2060 µm², 16% of the entire design — and it was never what
kept the bank alive. `(* keep *)` does that. the narrow reduction still
gives the bank a path to a primary output, so `opt_clean` cannot sweep
it as a self-contained toggle loop that reaches nothing.

so 64 is not a round number. it is the width that fits.

## fpga bench (area + delay)

`./fpga/bench.sh` builds the design for the tang nano 20k with the
open-source gowin flow (yosys → nextpnr-himbaechel → gowin_pack) and
prints a resource/timing report.

```
OSS_CAD_SUITE=/path/to/oss-cad-suite ./fpga/bench.sh
```

### how much fits

yosys 0.64, `synth_gowin -family gw2a`, aggressor at `WIDTH=64`:

| top | LUT-eq | DFF |
|---|---|---|
| `tangnano20k_top` — tile + LEDs + uart | 317.5 | 185 |
| `tt_um_rcyaon_droop` — what tapes out | 299.5 | 183 |
| `aggressor` alone | 175.0 | 95 |

none of that is close to filling a GW2AR-18, which has 20736 LUT4 and
15552 DFF. the design is roughly 2% of the part.

pin the toolchain version next to any of these numbers. yosys 0.68 maps
wide muxes differently and reports substantially larger area for the
same rtl, so 0.64 and 0.68 figures are not comparable.

### what the bench checks

the structural checks matter more than the area:

- **the ring is still a ring.** walking the netlist backwards from
  `g_dly[24]` through each input returns to the start after 26 cells: 25
  buffers (`INIT=10`) + 1 inverter (`INIT=01`). the enable gate folds
  into that inverter because `ui_in[7]` is tied high on the board, so
  the fpga build cannot park the oscillator.
- **nothing multi-bit crosses clock domains.** every RO-derived domain
  is a chain of lone toggle flops with no interior paths, and exactly
  one path crosses into `clk`, landing on the 2ff synchronizer.
- **all 10 `IO_LOC` entries place** on legal sites with their IO_TYPE
  and PULL_MODE applied. that is legality for the package, not agreement
  with the sipeed schematic — check that yourself before you flash.

the critical path is the saturating period counter at
`src/droop_sensor.v:78`, where the `== 14'h3fff` compare and the
increment share a carry chain. the last full place-and-route measured
3.50 ns on it — 285.80 MHz against a 37.04 ns budget from the 27 MHz
crystal. that run predates the `WIDTH=64` resize, which deletes cells
but does not touch this path. read the frequency printed *after*
routing: the post-placement estimate runs ~28% pessimistic.

### the fpga image is not the tile

only 6 of the 10 divider stages exist on the fpga. `TAP_SEL` is a
localparam in `tangnano20k_top` (`2'b01`, ÷64), so the tap mux folds to
`div[5]` and stages 6-9 are dead-code eliminated. `AGG_MODE` and
`AGG_LEN` are tied down the same way. on the asic all three arrive on
pins and every stage stays.

so the fpga build genuinely exercises the sensor and the aggressor — LUT
delay is supply- and temperature-dependent, so the RO really does track
VDD there — but it is a fixed-configuration cut of the tile, not the
tile.

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
| `uio[7]` | out | heartbeat ⊕ parity of `bank[7:0]` |

## footnotes

[^1]: sakurai & newton — "alpha-power law MOSFET model and its
    applications to CMOS inverter delay," IEEE JSSC, 1990

[^2]: larsson — "di/dt noise in CMOS integrated circuits," analog
    integrated circuits and signal processing, 1997

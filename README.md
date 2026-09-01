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

## bring-up plan

1. **baseline**: RO off vs on, log divided-RO frequency per tap on
   `uio[5]` with a scope or counter.
2. **static calibration (frequency mode)**: power the breakout from a
   bench supply, sweep VDD, record sample vs voltage. this is the
   sensor's transfer curve; everything after is read through it.
3. **droop (period mode)**: arm periodic bursts, trigger the scope on
   `uio[4]` (aggressor active), capture the sample stream on `uo[7:0]`
   with a logic analyzer clocked by `uio[3]` (valid). overlay burst
   length sweeps.
4. **cross-platform**: same RTL on the tang nano 20k (`fpga/`). LUT
   delays are also VDD-dependent, so the architecture demos end-to-end
   before silicon arrives; absolute numbers will differ, which is the
   point of having both.

## fpga (tang nano 20k)

synthesize `fpga/tangnano20k_top.v` + `src/*` in the gowin ide with the
`FPGA` define. S1 fires a burst, S2 held = calibration mode, LEDs show
the sample, and every valid sample streams out the usb-uart at 115200
(decimated when the uart is busy). **verify the .cst pin numbers against
the sipeed schematic before building**: they're from the common
examples, not gospel.

## hardening notes (read before submitting)

- the sky130 cells in `src/ro_osc.v` are instantiated directly and marked
  `(* keep *)`; yosys treats them as blackboxes and links them at
  techmap. this is the established tt pattern for hardware oscillators,
  but diff your synthesis stats and confirm the nand + 25 dlygates
  survived.
- the ripple divider clocks flops from other flops' outputs: expect
  generated-clock / unconstrained warnings from sta. they're benign
  here (edges only, single-bit cdc), but eyeball the log so you know
  which warnings are yours.
- cocotb needs `-DSIM` (set in `test/Makefile`); the tapeout build needs
  *no* defines; the fpga build needs `FPGA`.
- if the tile is congested, drop the aggressor to `WIDTH=96`: it only
  changes the size of the hammer.

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

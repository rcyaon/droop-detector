<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

A chip's supply voltage is not the flat number the datasheet promises. Whenever a lot of transistors switch at
the same moment they pull a spike of current, and the voltage at that spot on the die dips before the power
network can catch up. That dip is **supply droop**, and it matters because gates get *slower* when their supply
is lower — the instant a chip is busiest is the instant it is least able to meet its own clock. By the time the
dip reaches a package pin the board's decoupling capacitors have smoothed it away, so it has to be measured on
the die.

This tile does two things: it **makes** droop on command, in a controlled and repeatable way, and it **measures**
it, reporting the result as a plain byte you can read with a logic analyzer.

### A voltmeter made of logic gates

A **ring oscillator** is a chain of inverting gates wired in a loop, so the signal chases its own tail forever.
Nothing clocks it; its frequency is set by nothing but how fast its own gates switch. And how fast a gate
switches depends on its supply voltage: delay scales roughly with $C_L V_{DD} / I_D$, and the drive current
$I_D$ collapses as $(V_{DD}-V_{th})$ shrinks, so a few percent of droop turns into a few percent of frequency
shift.[^1]

That is the whole trick. Count the ring's frequency and you have measured the voltage, using a circuit made of
the same standard cells as everything else on the die. The ring sits *in* the tile it is measuring, so it sees
the same local supply as the logic around it.

### On the tile

- **The sensor.** A ring of 25 delay cells closed by a NAND gate — the NAND is both the loop's single inversion
  and its on/off switch. It oscillates far too fast to count directly, so a 10-stage ripple divider slows it
  down; you pick a tap from ÷16 to ÷1024. Exactly one bit crosses from the ring's clock domain into the system
  clock's, through a two-flop synchronizer. Nothing multi-bit ever crosses, which is what keeps that boundary
  safe.

- **The droop generator (aggressor).** 64 flip-flops that all toggle on the same clock edge, doing no useful
  work. Each toggle yanks a synchronized slug of current out of the tile's supply rail: a deliberate, repeatable
  di/dt event.[^2] It runs continuously, as a single burst on a trigger, or as periodic bursts, with the burst
  length selectable from 16 to 2048 cycles. The bank is 64 wide because that is what fits — at 128 flops the
  tile reached 82.65% utilization and detailed placement failed (`DPL-0036`) once clock-tree synthesis inserted
  its hold buffers. Narrowing the parity output from `^bank` to `^bank[7:0]` saved a further ~2060 µm² of XOR
  tree; that parity pin exists only so the toggling bank has a path to a real output and cannot be optimized
  away.

- **The measurement.** Two ways to turn the ring into a number:

  | mode | what it counts | good for |
  |---|---|---|
  | period | system-clock cycles in one divided-ring period | fast sampling — watching a droop event unfold |
  | frequency | divided-ring edges in an 8192-clock window | slow and precise — the static voltage-vs-count curve |

  In period mode the reading moves the intuitive way: **droop ⇒ ring slows ⇒ count rises**. Each new reading
  raises a `valid` strobe; if a count pins at 0xff a saturation flag goes high and you should pick a faster
  divider tap.

### What it can and cannot see

This measures the **envelope** of a supply excursion, not the sharp instantaneous notch. The sample rate is set
by the divided ring, so the resolution is microsecond-ish: you see the package- and board-level sag fighting the
decoupling capacitors, not the nanosecond spike underneath it. It is the same tradeoff as watching a glitch
through a scope with too little bandwidth — except the probe here is the victim circuit itself.

## How to test

A bench supply and a scope or logic analyzer are enough; no external hardware is required.

1. **Prove the counters first.** Set `uio[2]=1` and the sensor measures a clk/2 square wave instead of the ring.
   Period mode then reads 33 counts at tap ÷16 and 129 at ÷64 (the ÷16 and ÷64 periods of a clk/2 source, plus
   one clk of synchronizer offset), and pins at 0xff with `uio[6]` raised at ÷256. Wrong numbers there mean the
   divider, synchronizer or counters are broken rather than the supply. Clear `uio[2]` to go back to the ring.

2. **Check it is alive.** Toggle the ring enable (`ui[7]`) and watch the divided ring on `uio[5]` change from
   static to oscillating. Log its frequency at each divider tap.

3. **Calibrate (frequency mode).** Set `ui[6]=1`, sweep the supply from a bench supply, and record the sample
   byte on `uo[7:0]` against voltage. That curve is the sensor's ruler — every later measurement is read through
   it.

4. **Catch a droop (period mode).** Set `ui[6]=0`, arm periodic bursts (`ui[1:0]=11`), trigger your scope on
   `uio[4]` (aggressor active), and capture `uo[7:0]` clocked by `uio[3]` (valid). Sweep the burst length on
   `ui[5:3]` and overlay the captures — longer bursts should push the count further up.

### Pin summary

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
| `uio[7]` | out | heartbeat XOR parity of `bank[7:0]` |

## External hardware

None required. A bench supply with adjustable output is needed for step 3 (calibration), and a scope or logic
analyzer to capture `uo[7:0]`, `uio[3]` and `uio[5]`.

[^1]: Sakurai & Newton, "Alpha-power law MOSFET model and its applications to CMOS inverter delay," IEEE JSSC, 1990.

[^2]: Larsson, "di/dt noise in CMOS integrated circuits," Analog Integrated Circuits and Signal Processing, 1997.

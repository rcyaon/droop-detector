# SPDX-FileCopyrightText: 2026 lena conde araujo
# SPDX-License-Identifier: Apache-2.0

# two sources feed the measurement path, and the tests use both:
#
#   the ring (ui[7]).  in rtl sim ro_osc's behavioral model runs at
#   1/(2*8ns) = 62.5 MHz, so with tap /16 the sensor sees ~3.9 MHz and
#   period mode at a 50 MHz clk reports ~12-13 counts. this is the only
#   source that means anything on silicon, and the only one that cannot
#   run in gate-level sim: the hardened ring is a real combinational loop
#   and every sky130 FUNCTIONAL cell model is zero-delay, so releasing
#   ui[7] under GL wedges the event simulator at a single timestamp
#   forever (observed: a 6 h CI job that never advanced past t=600ns).
#   the ring tests below therefore skip themselves under GATES=yes.
#
#   the self-test source (uio[2]).  a clk/2 square wave, so every count
#   is exact and identical in rtl and gate level. this is what gives GL
#   real coverage of the divider, the synchronizer, both measurement
#   modes and the saturation flag.

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

GL = os.environ.get("GATES") == "yes"

# uio_out fields
VALID = 3
AGG_ACTIVE = 4
SAT = 6

# ui_in fields
RO_EN = 1 << 7
MODE_FREQ = 1 << 6
AGG_OFF, AGG_CONT, AGG_TRIG, AGG_AUTO = 0b00, 0b01, 0b10, 0b11
TRIG = 1 << 2

# uio_in fields
TAP16, TAP64, TAP256, TAP1024 = 0, 1, 2, 3
ST_SEL = 1 << 2

# with the self-test source the divider is driven at clk/2, so tap /16
# puts a ro_div edge every 32 clk cycles, /64 every 128, /256 every 512.
# period mode reports one clk more than that (the synchronizer's offset),
# hence the +/- 1 the checks below allow.
ST_PERIOD = {TAP16: 32, TAP64: 128, TAP256: 512}


def bit(sig, n):
    # read one bit, never the whole bus: uio_out[5] is ro_div, which is
    # X for as long as the ring is parked and unselected, and converting
    # the whole bus to an int would let that one bit fail every read of
    # every other bit.
    s = str(sig.value)  # MSB-first, one char per bit
    c = s[len(s) - 1 - n]
    assert c in "01", f"{sig._name}[{n}] is '{c}', expected 0 or 1"
    return int(c)


async def wait_valid(dut, timeout_cycles=20_000):
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if bit(dut.uio_out, VALID):
            return dut.uo_out.value.to_unsigned()
    raise AssertionError("no valid strobe seen")


async def setup(dut, ui=0, uio=0, clock=True):
    """Reset with the ring parked, then apply ui/uio.

    The ring must be parked across reset even when the test goes on to
    use it: on the hardened netlist every loop node powers up X, and with
    the enable low the closing nand2 is nand(x, 0) = 1, which propagates
    down the delay chain and leaves the loop defined. Drive the enable
    high from t=0 instead and the loop is X forever, since nand(x, 1) and
    every dlygate after it are all X.
    """
    if clock:  # one clock per test; cocotb kills it when the test ends
        cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())  # 50 MHz
    dut.ena.value = 1
    dut.ui_in.value = 0  # RO parked, aggressor off, period mode
    dut.uio_in.value = 0  # tap /16, ring selected
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 10)
    dut.uio_in.value = uio
    dut.ui_in.value = ui
    await ClockCycles(dut.clk, 10)


def skip_gl(dut, why):
    if GL:
        dut._log.info(f"skipped in gate-level sim: {why}")
    return GL


# ---- self-test source: runs in both rtl and gate level -----------------


@cocotb.test()
async def test_selftest_period(dut):
    """Period mode against a known clk/2 source, at two taps."""
    for n, tap in enumerate((TAP16, TAP64)):
        await setup(dut, uio=ST_SEL | tap, clock=(n == 0))
        samples = [await wait_valid(dut) for _ in range(3)]
        dut._log.info(f"self-test period samples at tap {tap}: {samples}")
        want = ST_PERIOD[tap]
        for s in samples[1:]:  # the first window after reset can be short
            assert abs(s - want) <= 1, f"period sample {s}, expected ~{want}"
            assert bit(dut.uio_out, SAT) == 0


@cocotb.test()
async def test_selftest_saturation(dut):
    """Tap /256 puts the period past 255 counts, so sample pins at 0xff."""
    await setup(dut, uio=ST_SEL | TAP256)
    samples = [await wait_valid(dut) for _ in range(3)]
    dut._log.info(f"self-test period samples at tap /256: {samples}")
    for s in samples[1:]:
        assert s == 0xFF, f"expected a saturated sample, got {s}"
        assert bit(dut.uio_out, SAT) == 1


@cocotb.test()
async def test_selftest_frequency(dut):
    """Frequency mode counts ticks in an 8192-clk window."""
    await setup(dut, ui=MODE_FREQ, uio=ST_SEL | TAP64)
    _ = await wait_valid(dut)  # discard the partial window
    s = await wait_valid(dut)
    dut._log.info(f"self-test freq sample at tap /64: {s}")
    want = 8192 // ST_PERIOD[TAP64]  # 64 ticks
    assert abs(s - want) <= 1, f"freq sample {s}, expected ~{want}"
    assert bit(dut.uio_out, SAT) == 0


# ---- aggressor: source-independent, runs in both ----------------------


@cocotb.test()
async def test_aggressor_modes(dut):
    await setup(dut, uio=ST_SEL)

    # continuous
    dut.ui_in.value = AGG_CONT
    await ClockCycles(dut.clk, 5)
    assert bit(dut.uio_out, AGG_ACTIVE) == 1

    # off
    dut.ui_in.value = AGG_OFF
    await ClockCycles(dut.clk, 5)
    assert bit(dut.uio_out, AGG_ACTIVE) == 0

    # triggered burst, len_sel=1 -> 32 cycles
    dut.ui_in.value = AGG_TRIG | (1 << 3)
    await ClockCycles(dut.clk, 5)
    dut.ui_in.value = AGG_TRIG | (1 << 3) | TRIG
    await ClockCycles(dut.clk, 6)  # sync + count-load latency
    assert bit(dut.uio_out, AGG_ACTIVE) == 1
    active_cycles = 0
    for _ in range(100):
        await ClockCycles(dut.clk, 1)
        active_cycles += bit(dut.uio_out, AGG_ACTIVE)
    assert 28 <= active_cycles <= 36, f"burst length {active_cycles} != ~32"
    assert bit(dut.uio_out, AGG_ACTIVE) == 0


# ---- the ring itself: rtl only ----------------------------------------


@cocotb.test()
async def test_period_mode(dut):
    if skip_gl(dut, "a hardened ring is a zero-delay loop under FUNCTIONAL"):
        return
    await setup(dut, ui=RO_EN)
    samples = [await wait_valid(dut) for _ in range(5)]
    dut._log.info(f"period-mode samples: {samples}")
    # behavioral ro /16 -> ~256ns period -> ~12.8 clk counts
    for s in samples[1:]:  # first sample after reset can be short
        assert 10 <= s <= 16, f"period sample {s} outside expected range"
        assert bit(dut.uio_out, SAT) == 0


@cocotb.test()
async def test_frequency_mode(dut):
    if skip_gl(dut, "a hardened ring is a zero-delay loop under FUNCTIONAL"):
        return
    await setup(dut, ui=RO_EN | MODE_FREQ)
    _ = await wait_valid(dut)  # discard partial window
    s = await wait_valid(dut)
    dut._log.info(f"freq-mode sample: {s}")
    # 8192 clk window = 163.84 us; ro/16 at ~3.9 MHz -> ~640 ticks -> saturates.
    # move to tap /64 and expect ~160.
    dut.uio_in.value = TAP64
    _ = await wait_valid(dut)
    s = await wait_valid(dut)
    dut._log.info(f"freq-mode sample at /64: {s}")
    assert 150 <= s <= 170, f"freq sample {s} outside expected range"

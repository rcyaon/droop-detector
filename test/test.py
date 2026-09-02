# SPDX-FileCopyrightText: 2026 lena conde araujo
# SPDX-License-Identifier: Apache-2.0

# behavioral RO in SIM mode runs at 1/(2*8ns) = 62.5 MHz. with tap /16
# that's ~3.9 MHz at the sensor, so period mode at a 50 MHz clk should
# report samples around 12-13 counts. the tests only verify the counting
# and control logic -- the physics obviously doesn't exist in rtl sim.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, with_timeout

VALID = 3
AGG_ACTIVE = 4
SAT = 6

# ui_in fields
RO_EN = 1 << 7
MODE_FREQ = 1 << 6
AGG_OFF, AGG_CONT, AGG_TRIG, AGG_AUTO = 0b00, 0b01, 0b10, 0b11
TRIG = 1 << 2


def bit(sig, n):
    # read one bit, never the whole bus. in gate-level sim `ro_div`
    # (uio_out[5]) is legitimately X forever: it is clocked by a real
    # combinational ring, and a ring that starts at X stays at X in an
    # event simulator -- nand2(x,1) is x, and so is every dlygate after
    # it. converting the whole bus to an int would let that one bit fail
    # every read of every other bit.
    s = str(sig.value)  # MSB-first, one char per bit
    c = s[len(s) - 1 - n]
    assert c in "01", f"{sig._name}[{n}] is '{c}', expected 0 or 1"
    return int(c)


async def wait_valid(dut, timeout_cycles=200_000):
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if bit(dut.uio_out, VALID):
            return dut.uo_out.value.to_unsigned()
    raise AssertionError("no valid strobe seen")


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())  # 50 MHz
    dut.ena.value = 1
    dut.ui_in.value = RO_EN  # oscillator on, aggressor off, period mode
    dut.uio_in.value = 0     # tap /16
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 10)


@cocotb.test()
async def test_period_mode(dut):
    await setup(dut)
    samples = [await wait_valid(dut) for _ in range(5)]
    dut._log.info(f"period-mode samples: {samples}")
    # behavioral ro /16 -> ~256ns period -> ~12.8 clk counts
    for s in samples[1:]:  # first sample after reset can be short
        assert 10 <= s <= 16, f"period sample {s} outside expected range"
        assert bit(dut.uio_out, SAT) == 0


@cocotb.test()
async def test_frequency_mode(dut):
    await setup(dut)
    dut.ui_in.value = RO_EN | MODE_FREQ
    _ = await wait_valid(dut)          # discard partial window
    s = await wait_valid(dut)
    dut._log.info(f"freq-mode sample: {s}")
    # 8192 clk window = 163.84 us; ro/16 at ~3.9 MHz -> ~640 ticks -> saturates.
    # move to tap /64 and expect ~160.
    dut.uio_in.value = 1
    _ = await wait_valid(dut)
    s = await wait_valid(dut)
    dut._log.info(f"freq-mode sample at /64: {s}")
    assert 150 <= s <= 170, f"freq sample {s} outside expected range"


@cocotb.test()
async def test_aggressor_modes(dut):
    await setup(dut)

    # continuous
    dut.ui_in.value = RO_EN | AGG_CONT
    await ClockCycles(dut.clk, 5)
    assert bit(dut.uio_out, AGG_ACTIVE) == 1

    # off
    dut.ui_in.value = RO_EN | AGG_OFF
    await ClockCycles(dut.clk, 5)
    assert bit(dut.uio_out, AGG_ACTIVE) == 0

    # triggered burst, len_sel=1 -> 32 cycles
    dut.ui_in.value = RO_EN | AGG_TRIG | (1 << 3)
    await ClockCycles(dut.clk, 5)
    dut.ui_in.value = RO_EN | AGG_TRIG | (1 << 3) | TRIG
    await ClockCycles(dut.clk, 6)  # sync + count-load latency
    assert bit(dut.uio_out, AGG_ACTIVE) == 1
    active_cycles = 0
    for _ in range(100):
        await ClockCycles(dut.clk, 1)
        active_cycles += bit(dut.uio_out, AGG_ACTIVE)
    assert 28 <= active_cycles <= 36, f"burst length {active_cycles} != ~32"
    assert bit(dut.uio_out, AGG_ACTIVE) == 0

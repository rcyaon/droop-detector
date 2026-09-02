#!/usr/bin/env bash
# Tang Nano 20K area + timing bench for the droop detector.
#
# runs the full open-source gowin flow and prints a resource/timing report:
#   yosys synth_gowin -> nextpnr-himbaechel (place, route, STA) -> gowin_pack
#
# tools come from oss-cad-suite. either put its bin/ on PATH, or:
#   OSS_CAD_SUITE=/path/to/oss-cad-suite ./fpga/bench.sh
#
# outputs land in fpga/build/ (gitignored). the design is synthesised with
# -DFPGA so ro_osc uses the gowin LUT1 delay chain rather than the sky130
# cells or the behavioural sim model.

set -euo pipefail
cd "$(dirname "$0")/.."

[ -n "${OSS_CAD_SUITE:-}" ] && export PATH="$OSS_CAD_SUITE/bin:$PATH"
for t in yosys nextpnr-himbaechel gowin_pack; do
  command -v "$t" >/dev/null || { echo "missing tool: $t (set OSS_CAD_SUITE)"; exit 1; }
done

BUILD=fpga/build
mkdir -p "$BUILD"

SRC="src/tt_um_rcyaon_droop.v src/ro_osc.v src/droop_sensor.v src/aggressor.v fpga/uart_tx.v fpga/tangnano20k_top.v"
DEVICE="GW2AR-LV18QN88C8/I7"   # Tang Nano 20K
FAMILY="GW2A-18C"
TARGET_MHZ=27                   # onboard crystal

yosys -V              > "$BUILD/ver_yosys.txt"   2>&1
nextpnr-himbaechel --version > "$BUILD/ver_nextpnr.txt" 2>&1

echo "[1/4] synthesis (top + per-block area)"
for top in tangnano20k_top tt_um_rcyaon_droop droop_sensor aggressor ro_osc uart_tx; do
  yosys -p "read_verilog -DFPGA $SRC; synth_gowin -family gw2a -top $top -json $BUILD/s_$top.json" \
        > "$BUILD/synth_$top.log" 2>&1
  printf "      %-22s ok\n" "$top"
done
cp "$BUILD/s_tangnano20k_top.json" "$BUILD/pnr_in.json"

echo "[2/4] place & route + static timing"
nextpnr-himbaechel \
    --json "$BUILD/pnr_in.json" --write "$BUILD/pnr_out.json" \
    --device "$DEVICE" --vopt family="$FAMILY" --vopt cst=fpga/tangnano20k.cst \
    --freq "$TARGET_MHZ" --detailed-timing-report \
    > "$BUILD/pnr.log" 2>&1
echo "      routed, timing analysed"

echo "[3/4] bitstream"
gowin_pack -d "$FAMILY" -o "$BUILD/droop.fs" "$BUILD/pnr_out.json" > "$BUILD/pack.log" 2>&1
echo "      $BUILD/droop.fs"

echo "[4/4] report"
BUILD="$BUILD" TARGET_MHZ="$TARGET_MHZ" DEVICE="$DEVICE" FAMILY="$FAMILY" python3 fpga/bench_report.py

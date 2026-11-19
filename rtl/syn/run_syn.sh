#!/usr/bin/env bash
# Synthesize each unit with Yosys + ABC onto Nangate45 (FreePDK45, the paper's node).
# Usage: syn/run_syn.sh [delay_target_ps]   (default 2000)
# Writes netlists to syn/out/<name>.v and a summary to syn/out/summary.tsv.
set -euo pipefail
cd "$(dirname "$0")/.."
LIB=lib/NangateOpenCellLibrary_typical.lib
D=${1:-2000}
OUT=syn/out/D$D
mkdir -p "$OUT"

# name : top module : chparam arguments
TARGETS=(
  "dp_int8:dp_int:-set W 8"
  "dp_int9:dp_int:-set W 9"
  "dp_lateshift:dp_lateshift:"
  "ot_flat8_trunc:ot_flat8:-set ROUND 0"
  "ot_flat8_nearest:ot_flat8:-set ROUND 1"
  "ot_flat8_even:ot_flat8:-set ROUND 2"
  "ot_wide9:ot_wide9:"
)

printf "name\tarea_um2\tcells\tdelay_ps\n" > "$OUT/summary.tsv"
for t in "${TARGETS[@]}"; do
  IFS=: read -r name top params <<< "$t"
  chp=""
  [ -n "$params" ] && chp="chparam $params $top;"
  yosys -q -l "$OUT/$name.log" -p "
    read_verilog -sv rtl/mx9_units.sv; $chp
    synth -top $top -flatten -booth;
    abc -liberty $LIB -D $D; opt_clean;
    rename $top $name;
    tee -o $OUT/$name.stat stat -liberty $LIB;
    write_verilog -noattr $OUT/$name.v" >/dev/null
  area=$(awk '/Chip area for module/ {print $NF}' "$OUT/$name.stat" | tail -1)
  cells=$(awk '/ cells$/ {print $1; exit} /Number of cells/ {print $NF; exit}' "$OUT/$name.stat")
  delay=$(grep -oE "Delay = *[0-9.]+" "$OUT/$name.log" | tail -1 | grep -oE "[0-9.]+$" || echo NA)
  printf "%s\t%s\t%s\t%s\n" "$name" "$area" "$cells" "$delay" >> "$OUT/summary.tsv"
done
column -t "$OUT/summary.tsv"

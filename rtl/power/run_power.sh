#!/usr/bin/env bash
# Real-activity power for every recorded VCD; writes power/power_real.tsv.
# Run from tmp/rtl on kuma: power/run_power.sh
set -euo pipefail
R=$(pwd)
OR=/OpenROAD-flow-scripts/tools/install/OpenROAD/bin/openroad
printf "case\tannotated_pins\tcomb_W\ttotal_W\n" > power/power_real.tsv
for v in power/*.vcd; do
  n=$(basename "$v" .vcd); d=${n%_A}; d=${d%_B}
  out=$(DESIGN=$d RUN=$R/work/syn/orfs/runs/${d}_P2.5 VCD=$R/$v \
        apptainer exec orfs.sif "$OR" -exit -no_init power/power.tcl 2>&1)
  pins=$(grep -oE "Annotated [0-9]+" <<<"$out" | grep -oE "[0-9]+" || echo NA)
  comb=$(awk '/^Combinational/{print $5}' <<<"$out")
  tot=$(awk '/^Total/{print $5}' <<<"$out")
  printf "%s\t%s\t%s\t%s\n" "$n" "$pins" "$comb" "$tot" >> power/power_real.tsv
done
cat power/power_real.tsv

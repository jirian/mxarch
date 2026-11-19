#!/usr/bin/env bash
# Formally prove a routed wrapper netlist equal to its RTL for all input sequences.
# The wrappers are feed-forward 2-register pipelines, so a 3-cycle bounded proof
# from an all-zero state covers every reachable behavior.
# Usage: formal/equiv.sh <wrapper> [timeout_s]
set -euo pipefail
cd "$(dirname "$0")/.."
D=$1; TO=${2:-600}
timeout "$TO" yosys -q -l build/equiv_$D.log -p "
  read_verilog -sv rtl/mx9_units.sv rtl/mx9_units_sm.sv rtl/reg_wrappers.sv rtl/reg_wrappers_sm.sv
  hierarchy -top $D; proc; flatten; opt_clean; rename $D gold; design -stash gold
  read_liberty -ignore_miss_func lib/NangateOpenCellLibrary_typical.lib
  read_verilog power/netlists/$D.v
  hierarchy -top $D; proc; flatten; opt_clean; rename $D gate; design -stash gate
  design -copy-from gold -as gold gold; design -copy-from gate -as gate gate
  miter -equiv -flatten -make_assert -ignore_gold_x gold gate miter
  hierarchy -top miter
  sat -verify -prove-asserts -seq 3 -set-init-zero -timeout $TO miter" >/dev/null 2>&1 \
  && echo "$D: PROVEN equivalent" || echo "$D: NOT proven (see build/equiv_$D.log)"

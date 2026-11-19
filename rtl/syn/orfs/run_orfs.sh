#!/usr/bin/env bash
# Run OpenROAD-flow-scripts (nangate45) for one wrapper at one clock period.
# Runs inside the ORFS Apptainer image:
#   apptainer exec orfs.sif syn/orfs/run_orfs.sh <design> <period_ns> [target]
# target defaults to "finish" (synthesis through detailed routing and reports).
set -euo pipefail
DESIGN=$1
PERIOD=$2
TARGET=${3:-finish}
RTL_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
RUN=$RTL_ROOT/syn/orfs/runs/${DESIGN}_P${PERIOD}
mkdir -p "$RUN"

cat > "$RUN/constraint.sdc" <<EOF
create_clock -name clk -period $PERIOD [get_ports clk]
set_input_delay  0 -clock clk [delete_from_list [all_inputs] [get_ports clk]]
set_output_delay 0 -clock clk [all_outputs]
# I/O registers stand in for neighbouring pipeline stages; only reg-to-reg
# paths through the unit are design paths, so skip hold checks at the ports.
set_false_path -hold -from [delete_from_list [all_inputs] [get_ports clk]]
set_false_path -hold -to [all_outputs]
EOF

cat > "$RUN/config.mk" <<EOF
export DESIGN_NAME     = $DESIGN
export DESIGN_NICKNAME = ${DESIGN}_P${PERIOD}
export PLATFORM        = nangate45
export VERILOG_FILES   = $RTL_ROOT/rtl/mx9_units.sv $RTL_ROOT/rtl/mx9_units_sm.sv $RTL_ROOT/rtl/reg_wrappers.sv $RTL_ROOT/rtl/reg_wrappers_sm.sv
export SDC_FILE        = $RUN/constraint.sdc
export CORE_UTILIZATION = 40
export PLACE_DENSITY   = 0.60
export ABC_AREA        = 0
export SKIP_CTS_REPAIR_TIMING = 1
EOF

source /OpenROAD-flow-scripts/env.sh >/dev/null 2>&1 || true
export PATH=/OpenROAD-flow-scripts/tools/install/OpenROAD/bin:/OpenROAD-flow-scripts/tools/install/yosys/bin:$PATH
export NUM_CORES=${NUM_CORES:-1}
make -C /OpenROAD-flow-scripts/flow DESIGN_CONFIG="$RUN/config.mk" WORK_HOME="$RUN" "$TARGET" \
  > "$RUN/make.log" 2>&1
echo "done: $RUN"

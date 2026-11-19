# Power of one routed wrapper from real-tensor switching activity.
# Usage: openroad -exit -no_init power.tcl  (env: DESIGN, RUN, VCD)
set base $::env(RUN)/results/nangate45/[file tail $::env(RUN)]/base
read_liberty /OpenROAD-flow-scripts/flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib
read_db $base/6_final.odb
read_sdc $base/6_final.sdc
read_spef $base/6_final.spef
read_vcd -scope tb_power/dut $::env(VCD)
report_power

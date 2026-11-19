"""Collect ORFS finish metrics for every run into one TSV.

logic_area: combinational cells, inverters and timing-repair buffers, i.e. the
unit itself, excluding I/O flip-flops, clock tree and tap cells.
crit_path_ns: clock period minus worst setup slack (the achieved delay).
Power uses the flow's default activity until real stimuli are applied.
"""
import glob
import json
import os
import re
import sys

root = sys.argv[1] if len(sys.argv) > 1 else "work/syn/orfs/runs"
rows = []
for run in sorted(glob.glob(os.path.join(root, "*_P*"))):
    m = re.match(r"(.+)_P([0-9.]+)$", os.path.basename(run))
    design, period = m.group(1), float(m.group(2))
    reports = glob.glob(os.path.join(run, "logs/nangate45/*/base/6_report.json"))
    if not reports:
        rows.append((design, period, "FAILED") + ("",) * 6)
        continue
    d = json.load(open(reports[0]))
    a = lambda c: d.get(f"finish__design__instance__area__class:{c}", 0.0)
    logic = a("multi_input_combinational_cell") + a("inverter") + a("timing_repair_buffer")
    ws = d["finish__timing__setup__ws"]
    rows.append((design, period, "ok", f"{d['finish__design__instance__area__stdcell']:.1f}",
                 f"{a('sequential_cell'):.1f}", f"{logic:.1f}", f"{ws:.3f}",
                 f"{period - ws:.3f}",
                 f"{d['finish__power__total'] * 1e3:.3f}"))
print("design\tperiod_ns\tstatus\tcell_area_um2\tseq_area_um2\tlogic_area_um2\tsetup_ws_ns\tcrit_path_ns\tpower_mW_default_activity")
for r in rows:
    print("\t".join(str(x) for x in r))

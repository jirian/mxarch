"""Scale per-lane RTL costs to a tensor core and an SM (H100-like), area only.

Inputs: ORFS logic areas (syn/orfs/results_tc.tsv, 2.5 ns runs, where every
unit meets timing). Assumptions, each stated in the output:

- An H100 tensor core performs 1024 dense INT8 MACs per clock
  (989 TFLOPS FP16 = 132 SMs x 1.83 GHz x 2048 FMA x 2; INT8 is 2x FP16),
  i.e. 64 lanes of 16-element dot products.
- Avant-Garde flattens operands as they are read (Operand Transformer between
  operand read and execute). An m16n8k32 INT8 MMA reads 16x32 + 32x8 elements
  = 48 blocks over 4 clocks, so 12 block-wide transformers per tensor core.
- Tensor-core share of SM area is inferred from the paper: the redesigned
  tensor core adds 3.9% of a tensor core and the Operand Transformer 1.2% of an
  SM, for 1.4% overall, so 3.9% x TC/SM = 0.2% gives TC/SM ~ 5%.
- The per-block scaling unit after the adder tree is the same in (a), (b), (c)
  and is not modelled.
"""
import csv
import os

HERE = os.path.dirname(os.path.abspath(__file__))
LANES_PER_TC = 64
OT_PER_TC = 12
TC_SHARE_OF_SM = 0.002 / 0.039       # from the paper's 3.9% -> 0.2% split
PAPER_OT_SHARE_OF_SM = 0.012

area = {}
with open(os.path.join(HERE, "..", "syn", "orfs", "results_tc.tsv")) as f:
    for row in csv.DictReader(f, delimiter="\t"):
        if row["status"] == "ok" and float(row["period_ns"]) == 2.5:
            area[row["design"]] = float(row["logic_area_um2"])

lane8 = area["reg_dp_int8"]
designs = {
    "(a) Avant-Garde: flatten (nearest) + INT8 lane": (lane8, area["reg_ot_flat8_nearest"]),
    "(a) Avant-Garde: flatten (trunc) + INT8 lane": (lane8, area["reg_ot_flat8_trunc"]),
    "(b) 9-bit operands: widen + 9x9 lane": (area["reg_dp_int9"], area["reg_ot_wide9"]),
    "(c) late shift lane, no transformer": (area["reg_dp_lateshift"], 0.0),
}
base_tc = LANES_PER_TC * lane8
print(f"Tensor-core lane array (64 x INT8 lane): {base_tc:,.0f} um^2 (Nangate45)")
print(f"Assumed TC share of SM area: {TC_SHARE_OF_SM:.1%}\n")
print(f"{'design':50s} {'lanes':>9s} {'OTs':>8s} {'vs INT8 TC':>11s} {'of SM':>7s}")
for name, (lane, ot) in designs.items():
    lanes = LANES_PER_TC * lane
    ots = OT_PER_TC * ot
    rel = (lanes + ots) / base_tc - 1
    print(f"{name:50s} {lanes:9,.0f} {ots:8,.0f} {rel:+10.1%} {rel * TC_SHARE_OF_SM:+7.2%}")

late = area["reg_dp_lateshift"] / lane8 - 1
print(f"\n(c) vs (a), our minimal transformer: {(late - OT_PER_TC * area['reg_ot_flat8_trunc'] / base_tc) * TC_SHARE_OF_SM:+.2%} of SM")
print(f"(c) vs (a), paper's transformer (1.2% of SM): {late * TC_SHARE_OF_SM - PAPER_OT_SHARE_OF_SM:+.2%} of SM")

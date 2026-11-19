# Results summary (working notes for the poster and final report)

State as of 2026-11-19. Each number names the file it comes from. Pending runs
are marked; nothing here is final until those land.

## 1. Accuracy: flattening penalty (H1)

Protocol: status-report Wikipedia text, MX9 conversion rounding nearest,
dequantized backend, FP32 between GEMMs unless noted. Delta_PPL is flattened vs
non-flattened (hierarchical) MX9, paired bootstrap 95% CI over windows
(2,000 resamples). Source: `rtl/analysis/grid_summary.tsv`
(`emulator/scripts/grid_summary.py` over cluster runs `grid-gpt2-5006342`,
`grid-qwen3-5006343`).

| Model (ctx) | Activations | Flatten: nearest | Flatten: trunc |
|---|---|---|---|
| GPT-2 S (1k) | FP32 | +3.72 [3.40, 4.08] | +3.71 [3.39, 4.00] |
| GPT-2 S (1k) | MX9 | +3.76 [3.27, 4.25] | +3.83 [3.37, 4.27] |
| GPT-2 M (1k) | FP32 | +3.32 [3.01, 3.66] | +3.41 [3.14, 3.69] |
| GPT-2 M (1k) | MX9 | +3.69 [3.18, 4.20] | +3.66 [3.24, 4.09] |
| GPT-2 L (1k) | FP32 | +0.12 [0.06, 0.18] | +0.08 [0.02, 0.13] |
| GPT-2 L (1k) | MX9 | +0.13 [0.03, 0.23] | -0.04 [-0.12, 0.04] |
| GPT-2 XL (1k) | FP32 | +0.14 [0.09, 0.19] | -0.03 [-0.08, 0.01] |
| GPT-2 XL (1k) | MX9 | +0.19 [0.12, 0.26] | -0.00 [-0.08, 0.07] |
| Qwen3-8B (2k) | FP32 | +1.10 [0.93, 1.27] | **-0.64 [-0.79, -0.51]** |
| Qwen3-8B (2k) | MX9 | +1.22 [1.01, 1.44] | **-0.70 [-0.88, -0.55]** |

- The nearest/FP32 column reproduces the submitted status report exactly.
- Backend check (Figure 8 vs dequantized): GPT-2 S +3.75 vs +3.83 (CIs
  overlap); Qwen3-8B, 4 windows, -0.59 vs -0.52. The backend does not matter.
- Activation policy (FP32 vs MX9 storage at non-GEMM boundaries) moves the
  penalty by at most 0.4 points.
- Qwen3-8B FP32 perplexity on the same 64 windows is 9.999; hierarchical MX9
  9.974 (-0.25%, open question N2); flattened nearest 10.084 (+0.85% vs FP32);
  flattened trunc 9.910 (-0.89% vs FP32). Truncation moves perplexity further
  from FP32, downward: a bias, not higher fidelity.

Real operand statistics (Qwen3-8B, layers 0/17/35 and LM head, one 512-token
window; `rtl/vectors/power_vectors_stats.json`): 69-82% of activation pairs
and 67-70% of weight pairs use the finer microexponent, so flattening drops a
bit from most pairs.

The rounding flip holds beyond the grid (same settings):

| Run | Flatten: nearest | Flatten: trunc |
|---|---|---|
| Qwen3-8B 8k, Wikipedia (16 windows) | +1.26 (status report) | -0.74 [-0.93, -0.59] |
| Qwen3-8B 2k, WikiText-2 (64 windows) | +1.29 [1.13, 1.44] | -0.83 [-0.95, -0.71] |
| Qwen3-30B-A3B 2k, Wikipedia (16 windows) | +2.50 [2.10, 2.93] | -1.46 [-1.76, -1.16] |

WikiText-2 perplexities: FP32 9.620, hierarchical 9.606, flattened nearest
9.729, flattened trunc 9.526. Sources: `eval-rounding-5008194`,
`moe-rounding-5008245`, `qwen3-8k-trunc-5008246`.

Pending:
- `eval-rounding-5008194` (running): ARC-Challenge / HellaSwag accuracy.
  WikiText-2 is also Wikipedia-derived, so accuracy decides whether the
  truncation drop is a real gain or a bias.
- `moe-groups-5009532`: H1.1 layer-group breakdown (job 5008245's group stage
  failed on a bash name clash; full-flattening runs are complete).

## 2. Hardware cost of lossless flattening (H1.2)

Designs: (a) Avant-Garde flattening (8-bit, lossy) + INT8 dot product;
(b) 9-bit flattened operands + 9x9 dot product (lossless); (c) late shift of
each 8x8 product by 2 - mu_a - mu_b in {0, 1, 2} (lossless).

Verification: all units match the emulator's golden values bit for bit on
60,030 synthetic and 6,656 real Qwen3-8B block pairs (RTL in Verilator and
Icarus, synthesized and routed netlists in Verilator); mutation tests confirm
the testbenches catch injected bugs.

Flow: OpenROAD-flow-scripts, Nangate45 (FreePDK45, the paper's node), full
place and route, register-to-register wrappers; logic area excludes I/O
flip-flops, clock tree and taps. Sources: `rtl/syn/orfs/results_tc.tsv`,
`results_sm.tsv`; power `rtl/power/power_real.tsv` (VCD from real Qwen3-8B
operands, routed netlist with extracted parasitics, 2.5 ns).

Per lane, two's complement, 2.5 ns:

| Unit | Logic area (um^2) | Power (mW) | Fastest path (ns) |
|---|---|---|---|
| INT8 dot product | 8,714 | 4.90 | 2.13 |
| (b) 9x9 dot product | 10,643 (+22%) | 5.80 (+18%) | 2.27 |
| (c) late shift | 10,010 (+15%) | 5.78 (+18%) | 2.26 |
| (a) flattening, per operand block | 842-863 | 0.43 | 0.40 |
| (b) widening, per operand block | 449 | 0.26 | 0.27 |

Sign-magnitude (MX9's native element encoding), logic area: lane 7,257
(-17% vs two's-complement INT8), (b) 9,124, (c) 8,951; truncating flattening
385 per block (a pure shift). Sign-magnitude power: pending (activity files
recorded, OpenSTA step needs the cluster).

Per tensor core (`rtl/analysis/gpu_scaling.py`): 64 lanes (1,024 INT8 MAC/clk)
and 12 block transformers (an m16n8k32 MMA reads 48 blocks over 4 clocks).

| Design | Area vs INT8 TC | Power vs INT8 TC | Share of SM area |
|---|---|---|---|
| (a) Avant-Garde, our minimal transformer | +1.9% | +1.7% | +0.10% |
| (b) 9-bit operands | +23.1% | +19.4% | +1.19% |
| (c) late shift | +15.1% | +18.0% | +0.77% |
| (c) late shift, sign-magnitude | +2.7% | pending | +0.14% |

The SM column assumes tensor cores are ~5% of SM area, inferred from the
paper's 3.9% (tensor core) and 1.4% (overall) figures; the paper's own Operand
Transformer is 1.2% of an SM. Not modelled: the per-block scaling unit after
the adder tree (identical in all designs), operand bandwidth (+6.25% for (c),
which keeps 8 mu bits per 128-bit block; +12.5% for (b)).

### Throughput

All three designs keep the INT8 tensor core's issue rate: one 16-element dot
product per lane per clock. The lossless designs lengthen the lane's critical
path by 6-7% (2.13 -> 2.26/2.27 ns at the tightest target). In a pipelined
tensor core this is absorbed by rebalancing or at most one extra pipeline
stage, i.e. MMA latency rises by at most one cycle (IMMA latency measured at
24 cycles, so about 4%), with no change in throughput. Avant-Garde's Operand
Transformer adds two cycles per warp for multi-level formats (paper, section
3.3); design (c) removes that stage, so its operand-to-result latency is at
most Avant-Garde's. Decode GEMMs, which are memory-bound (H2), hide such
latency entirely.

## 3. Performance (H2, from the status report)

Software-scaled MX GEMMs vs plain INT8 on H100: prefill 1.67x (MXINT8) and
3.96x (MX9); decode (tuned) 1.26x and 2.14x. Scaling overhead is
instruction-issue bound, not memory bound. Not yet done: H2.1 decode
attention, H3 prefill residual work, N1 k16 baseline rebuild.

## 4. Open items before the final report

1. Read the three pending jobs; settle the H1 narrative (rounding mode).
2. Sign-magnitude power (OpenSTA on the cluster).
3. Run the accumulator sensitivity (`--accumulator bf16|fp16|fp32-m14`;
   tests pass on kuma).
4. Decide on H2.1, H3, N1, long generation, MX6/MX4 (cut or run).
5. Fix the report's numerics section: equation (2) says floor; define
   sign-magnitude truncation and round-to-nearest.

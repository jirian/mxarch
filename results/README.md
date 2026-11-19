# Cluster results

Outputs of every job run on EPFL's kuma cluster (H100 / L40S) for this project,
copied from `/work/cs-471/mixedprecisionarchitects/avant-garde/runs/`.
`cluster/runs/<name>-<slurm job id>/` holds the result files of one job,
`cluster/slurm-logs/` its standard output. Each emulator run directory has a
`git-commit.txt` naming the emulator commit it ran (cluster runs from
2026-11-19 on name `4aae500`, which is `e98fc57` in this repository).

The two MoE directories (`qwen3-moe-4871872`, `moe-rounding-5008245`) were
slimmed: per-module diagnostics, coverage and exemption counters (tens of MB
per file) are removed; metrics, per-window losses, confidence intervals and
configuration are kept (see `SLIMMED.txt` there).

## Where each result comes from

### Accuracy (emulator, `emulator/`)

| Run | Experiment | Used for |
|---|---|---|
| `calib-4859947`, `xsize-4860058`, `xsize-4860082` | GPT-2 calibration and size sweep, MXINT8 cross-check | status report H1 |
| `fallback-4860592` | GPT-2 LM-head / layer fallback | H1.1 (GPT-2) |
| `qwen3-4866221` (failed), `qwen3-4866272` | Qwen3-8B, first runs | status report |
| `qwen3-robust-4871871` | Qwen3-8B 2k (64 windows), 8k (16), LM-head fallback; FP32 reference | H1, N2 |
| `qwen3-moe-4871872` | Qwen3-30B-A3B, round to nearest | H1 (MoE) |
| `grid-gpt2-5006342`, `grid-qwen3-5006343` | 2x2 grid: flattening rounding x activation policy; Figure 8 vs dequantized backend | Table I, Fig. 1 |
| `qwen3-8k-trunc-5008246` | Qwen3-8B 8k, truncation | Table I |
| `eval-rounding-5008194` | WikiText-2 perplexity; ARC-Challenge / HellaSwag accuracy (`mc.json`) | Table I, task-accuracy table |
| `moe-rounding-5008245` | MoE nearest vs trunc; one layer group flattened at a time | Table I, layer-group table |
| `moe-policy-5012007` | MoE static policy: experts + router flattened | H1.1 validation |
| `acc-gpt2-5009655`, `acc-h3-qwen3-5009656` | Accumulator format sensitivity (Figure 8 backend) | accumulator paragraph |

Summaries: `emulator/scripts/grid_summary.py <run dirs>` (perplexity deltas
with paired bootstrap CIs), `emulator/scripts/moe_groups_summary.py
cluster/runs/moe-rounding-5008245`, `mc.json` (`vs_hier` field) for accuracy.

### Performance (H100 kernels, `perf/`)

| Run | Experiment | Used for |
|---|---|---|
| `ncu-4860059`, `ncu-4860083` | Nsight Compute attempt (blocked counters) | methodology note |
| `ubench-4865834` | `clock64()` instruction latency / throughput | issue-rate bound |
| `nvbit-4865838`, `nvbit-4865840` | NVBit opcode histograms | instruction counts (4x, 8.2x) |
| `mxgemm-4865967`, `mxgemm-4865968` | Square GEMMs, INT8 / MXINT8 / MX9 | performance table |
| `mxgemm-llm-4865978`, `mxgemm-decode-4865996` | Qwen3-8B layer shapes, prefill and decode, roofline | H2 |
| `mxgemm-k16-5009676` | INT8 issued as k16 (N1) | N1 (rejected) |
| `acc-h3-qwen3-5009656` (`h3-layer-profile.json`), `h3-fused-5012008` | One Qwen3-8B prefill layer, eager and fused attention | H3 |

### Hardware (RTL, `rtl/`)

Synthesis, place-and-route and power results are in `rtl/syn/orfs/results_tc.tsv`,
`rtl/syn/orfs/results_sm.tsv` and `rtl/power/power_real.tsv`; per-tensor-core
scaling in `rtl/analysis/gpu_scaling.py`. The full OpenROAD run directories
(GDS, DEF, reports) remain on kuma under `tmp/rtl/work/syn/orfs/runs/`.

# How Avant-Garde Scales to Large LLM Inference

CS-471 project (EPFL, fall 2026): reproduction and extension of Avant-Garde
(ISCA 2025), hardware support for scaled numeric formats on GPUs. We test its
accuracy claim on Qwen3 dense and MoE models, measure the overhead it removes
on an H100, and compare its lossy flattening with lossless tensor-core lanes in
placed-and-routed RTL.

| Folder | Contents |
|---|---|
| `emulator/` | PyTorch MX9 emulator (GPT-2, ViT, Qwen3 dense/MoE), team history merged |
| `perf/` | H100 GEMM kernels: INT8, MXINT8, MX9 software scaling, k16 INT8 baseline |
| `rtl/` | Lane RTL, golden vectors, testbenches, synthesis, place-and-route, power, formal checks |
| `results/` | Every cluster job's outputs, with an index (`results/README.md`) |
| `RESULTS.md` | All reported numbers with their source files |

## Commit hashes

The emulator history was imported with tool-attribution trailers removed from
commit messages, which changes some hashes. Cluster runs refer to the original
merge commit `4aae500`, which is `e98fc57` here.

## Reproducing the experiments

All GPU jobs ran on EPFL's kuma cluster (Slurm account `cs471`; H100 and L40S
partitions). Paths in the job scripts point to the team's shared directory;
adjust `BASE` for another installation.

### 1. Accuracy (emulator)

Environment: Python 3.11, PyTorch 2.x with CUDA, `transformers >= 4.51` (Qwen3),
`datasets`, `pytest` (see `emulator/pyproject.toml`). Tests: `cd emulator &&
python -m pytest -q` (CPU; one GPU-only test is skipped).

Data: the Wikipedia evaluation text is built by
`emulator/scripts/make_wikipedia_text.py`; WikiText-2, ARC-Challenge and the
HellaSwag subset by `emulator/scripts/prepare_eval_data.py`.

One perplexity run (flattened vs non-flattened MX9, with paired bootstrap CIs):

```
python -m avant_garde.cli gpt2 --device cuda --offline --text-file <text> \
  --model Qwen/Qwen3-8B --context 2048 --windows 64 --rounding nearest \
  --flatten-rounding trunc --activation-policy fp32 --backend dequantized \
  --modes fp32 mx9_hierarchical mx9_flattened --output out.json
```

Key options: `--flatten-rounding nearest|trunc|even` (rounding of the dropped
bit), `--activation-policy fp32|hierarchical`, `--backend dequantized|figure8`,
`--accumulator fp32|bf16|fp16|fp32-m14` (Figure 8 only), `--exempt <regex>
--exempt-mode <mode>` (layer fallback), `--device-map auto --no-weight-cache`
(the 30B MoE model on two GPUs).

Job scripts (`emulator/scripts/slurm/`) for each reported experiment:

| Script | Experiment |
|---|---|
| `qwen3_robust_h100.sbatch`, `qwen3_moe_h100x2.sbatch` | Status-report Qwen3 runs |
| `grid_gpt2_l40s.sbatch`, `grid_qwen3_h100.sbatch` | Rounding x activation grid |
| `qwen3_8k_trunc_h100.sbatch` | Qwen3-8B 8k, truncation |
| `eval_qwen3_rounding_h100.sbatch` | WikiText-2 and ARC/HellaSwag (`scripts/mc_eval.py`) |
| `moe_rounding_groups_h100x2.sbatch`, `moe_groups_h100x2.sbatch` | MoE rounding and layer groups |
| `moe_policy_h100x2.sbatch` | MoE static flattening policy |
| `accumulator_gpt2_l40s.sbatch`, `accumulator_h3_qwen3_h100.sbatch` | Accumulator formats; H3 eager profile |
| `h3_fused_h100.sbatch` | H3 with fused attention (`scripts/h3_layer_profile.py`) |

Summaries: `scripts/grid_summary.py <run dirs>`, `scripts/moe_groups_summary.py
<moe run dir>`.

### 2. Performance (H100 kernels)

```
nvcc -O3 -std=c++17 -arch=sm_90 -lineinfo -o mxgemm4 perf/mxgemm4.cu
./mxgemm4            # verifies all variants exactly, then times Qwen3-8B layer shapes
```

`mxgemm3.cu` is the version behind the status report; `mxgemm4.cu` adds the
k16 INT8 baseline (N1); `perf/mxgemm4_h100.sbatch` is the job. Instruction
counts used NVBit's opcode histogram, latencies `clock64()` microbenchmarks
(runs `nvbit-*`, `ubench-*` in `results/`).

### 3. Hardware (RTL)

Local tools: Verilator, Icarus Verilog, Yosys. Place-and-route and power use
the OpenROAD-flow-scripts image under Apptainer (`apptainer pull orfs.sif
docker://openroad/orfs:latest`).

```
cd rtl
lib/fetch_lib.sh                                  # Nangate45 liberty
# golden vectors from the emulator (needs emulator/ on PYTHONPATH)
python vectors/gen_vectors.py --out vectors/vectors.hex
# simulate every unit against the golden values
verilator --binary --top-module tb_mx9_units -Mdir build/v rtl/mx9_units.sv tb/tb_mx9_units.sv -o tb && ./build/v/tb
verilator --binary --top-module tb_mx9_units_sm -Mdir build/vsm rtl/mx9_units.sv rtl/mx9_units_sm.sv tb/tb_mx9_units_sm.sv -o tb && ./build/vsm/tb
syn/run_syn.sh                                    # quick Yosys area
# place and route one wrapper at one clock period (inside the ORFS image)
apptainer exec orfs.sif syn/orfs/run_orfs.sh reg_dp_lateshift 2.5
python syn/orfs/collect.py > syn/orfs/results_tc.tsv
formal/equiv.sh reg_ot_flat8_trunc               # formal proof, routed netlist vs RTL
python analysis/gpu_scaling.py                    # per-tensor-core and per-SM costs
```

Power from real activity: `vectors/capture_qwen3.py` captures Qwen3-8B operand
blocks; `power/tb_power.sv` replays them through a routed netlist (Verilator,
`+define+DUT_<wrapper>`) and dumps a VCD; `power/run_power.sh` runs OpenSTA
(`power/power.tcl`) on every VCD. Sweeps: `syn/orfs/sweep.sbatch`,
`sweep_sm.sbatch`.

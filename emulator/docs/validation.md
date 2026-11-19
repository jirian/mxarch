# CPU validation and GPU handoff

## Truncation and hierarchical activation policy, 2026-11-10

The expanded CPU suite passed **68 tests, with one CUDA-only test skipped**
(`python -m pytest -ra`, 69.53 seconds) before the first GPU attempt. New cases
check independent flatten/conversion rounding settings, signed-magnitude shifts,
unflatten scale reconstruction, permanently lost fractional bits, complete
FP32 LayerNorm/GELU followed by MX9 storage, masked softmax, and an explicit
linear/GELU/linear pipeline reference. GPT-2/ViT validate all expected activation
boundaries; a missing ViTOutput residual boundary was detected and fixed.
Mock Slurm tests check the 14-task mapping, fixed GPT-2 input-token budget,
numerical flags, offline mode and partial-result plots.

GPU smoke **4883676** passed 19 arithmetic/conversion tests and the tiny ViT
forward, but stopped on pretrained GPT-2 because the experimental signed-int8
exponent-sum guard rejected a valid internal scale combination. Its dependent
sweep **4883678** was cancelled automatically, and summary **4883697** found no
completed sweep reports. These jobs do not constitute a completed experiment.
The revised default keeps mathematical exponent sums (`wide`) and rounds only
at the FP32 scaling unit; `error`/`wrap` remain opt-in sensitivity settings.
A CPU regression checks `64 * 64 * 2**(-120-10) == 2**-118`: the exponent sum
falls outside int8 although the output is normal FP32.

After that correction, the affected CPU suites passed **41 tests, one CUDA
skip**, and the offline GPT-2/ViT runner test passed again after adding the ViT
hierarchical/lossless metric assertion. Replacement GPU smoke **4883749** then
completed successfully on L40S (59 seconds): **20 arithmetic/conversion checks**,
tiny ViT, two GPT-2 windows at context 128, all four modes, and CSV/PNG export.
GPT-2 perplexities were FP32 **40.180217**, hierarchical **41.164803**, flattened
with truncation **45.537864**, and lossless **41.164803**. This is a functionality
sample, not an estimate of full-dataset degradation. Coverage included 24
softmax and GELU events, 50 normalization and residual/position events, and four
embedding events for each quantized mode. Quantized runs report hierarchical
activations, magnitude truncation and wide mathematical scale sums.

Full sweep **4883757** was submitted after that successful smoke, with 14 tasks
(four GPT-2 sizes × three contexts, plus two ViTs), one L40S at a time. Summary
job **4883760** depends on completion of that array and writes combined graphs,
including completed reports if any task fails. Results are under
`/work/cs-471/mixedprecisionarchitects/avant-garde-reproduction/runs/hierarchical-4883757/`.
Smoke artifacts are under the sibling `figure8-smoke-4883749/` directory.
The full sweep was still in progress when these changes were handed off.

The plotting queue requires a GPU GRES (`QOSMinGRES`), so the summary script
requests a small 12 GB H100 MIG slice while running matplotlib on the CPU.
Every completed array task also writes its own plot before the final summary.

## Original Figure 7/8 backend validation, 2026-11-10

The full CPU suite passed: **53 passed, 1 skipped**, using the interpreter below
(`python -m pytest -ra`, 44.77 seconds). The skipped test is CPU/CUDA equality;
it is enabled only by `AVANT_GARDE_TEST_CUDA=1` in the new Slurm smoke job.

New checks exhaust all signed MX9 codes, all pair positions, both secondary
scales, and three rounding policies for Figure 7. An independent scalar oracle
checks Figure 8 block dots, scaling, and FP32 accumulation with partial blocks,
noncontiguous inputs, and biases. Further cases cover broadcast batches,
hierarchical/lossless equality, explicit exponent wrap/error/wide policies,
subnormal scaling, overflow/cancellation, and pipeline rounding order. Tiny
GPT-2 and ViT tests and offline CLI evaluations now exercise the Figure 8 backend.
The legacy backend and native FP32 control remain covered.

`bash -n scripts/slurm/figure8_smoke_l40s.sbatch` and `git diff --check` passed.
The script is ready for user submission; no GPU job was submitted for this
change. It checks CPU/CUDA equality, tiny ViT, and GPT-2 Small on two 128-token
windows, then produces a normalized graph. These checks precede new full
model/context sweeps. Existing pretrained results used the previous backend.
See [the numerical contract](numerics.md#figure-8-numerical-execution-contract)
for the paper's unspecified details and the assumptions used here.

## Earlier backend validation

Validated on 2026-11-04 with this interpreter:

`/home/santanto/miniconda3/envs/nanofm/bin/python`

| Component | Version |
| --- | --- |
| Python | 3.10.20 |
| PyTorch | 2.10.0+cu128 |
| Transformers | 4.48.3 |
| datasets | 4.1.1 |
| NumPy | 1.26.4 |
| Pillow | 12.1.1 |
| pytest | 9.0.3 |
| matplotlib | 3.10.8 |

CPU suite: `python -m pytest` (31 tests). This covers independent numerical
references; boundary values and padding; baseline parity; hierarchical/lossless
equality; both attention products; linear and patch projections; cache behavior;
unchanged/tied parameters; offline local checkpoint loading; perplexity and
classification accounting; configuration, serialization, summaries and plotting.
Normalized bar heights are checked independently for perplexity and accuracy,
including undefined ratios when unquantized accuracy is zero.
Additional CPU tests verify class-balanced ImageNet sampling, validation-only
downloads using a local Parquet fixture, data-root selection, and Slurm script
orchestration with a mock interpreter (no job submissions or CUDA execution).
All fixtures use CPU tensors. Local model, tokenizer, image and text fixtures
are created under pytest temporary directories; no pretrained downloads occur.

Additional checks: `bash -n scripts/slurm/smoke_l40s.sbatch`, Python bytecode
compilation, and `git diff --check`.

Slurm resource names were confirmed with `sinfo`: partition `l40s`, GRES
`gpu:nvidia_l40s`. The first user-submitted GPU smoke run completed as job
4828405; its [results are recorded separately](smoke-4828405.md).

The original smoke job described in README.md checks
CUDA availability, tiny ViT hierarchical/lossless parity, expected operation
coverage, finite outputs, and GPT-2 Small perplexity in four modes. It also checks
that GPT-2 hierarchical and lossless controls produce identical metrics.
Subsequent pretrained model/context and ImageNet runs used the dequantized
backend. Those results do not validate the new Figure 8 backend's CUDA behavior
or performance. All numerical reconstruction assumptions are in
[numerics.md](numerics.md).

# CPU validation and GPU handoff

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

The next validation is the submitted smoke job described in README.md. It checks
CUDA availability, tiny ViT hierarchical/lossless parity, expected operation
coverage, finite outputs, and GPT-2 Small perplexity in four modes. It also checks
that GPT-2 hierarchical and lossless controls produce identical metrics.
Pretrained accuracy, GPU runtime/memory behavior, compute-node network access,
and full model/context sweeps remain unmeasured. All numerical reconstruction
assumptions are in [numerics.md](numerics.md).

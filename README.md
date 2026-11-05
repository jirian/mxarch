# Avant-Garde software reproduction

Run GPT-2 and ViT with FP32, hierarchical MX9, flattened MX9, and lossless
flattening controls using PyTorch. This is an inference-only numerical
reconstruction. See [the numerical contract](docs/numerics.md) for equations,
sources, assumptions and comparison limits.
New evaluations include bootstrap SD and normalized error bars. See
[uncertainty and context sweeps](docs/uncertainty.md) for their interpretation
and the GPT-2 sweep at contexts 128, 512 and 1024.
Exact Hugging Face repositories, splits, subset selection and provenance fields
are documented in [dataset sources](docs/datasets.md).

## CPU validation

Use an environment containing the dependencies in `pyproject.toml`.
From the repository root (installation is optional):

```bash
PYTHON=/home/santanto/miniconda3/envs/nanofm/bin/python
"$PYTHON" -m pytest
bash -n scripts/slurm/smoke_l40s.sbatch
```

CPU tests use tiny random models, with no downloads or CUDA. On a new environment,
install with `python -m pip install -e '.[test]'`; plotting also needs `.[plot]`.
The machine's base conda environment lacks these dependencies.

## First scheduled GPU test

Submit from this repository root after reviewing the script:

```bash
export AVANT_GARDE_PYTHON=/home/santanto/miniconda3/envs/nanofm/bin/python
sbatch scripts/slurm/smoke_l40s.sbatch
```

This requests partition `l40s`, one `nvidia_l40s` GPU, six CPUs, 32 GB memory and
one hour. It runs a tiny ViT GPU numerical test, then GPT-2 Small on 32 WikiText-2
validation windows of 128 tokens in all four modes. The ViT smoke is not an
ImageNet accuracy evaluation. The job also saves `comparison.csv` and a
normalized GPT-2 bar graph, `comparison.png`, in its run directory. Plotting
requires matplotlib (`.[plot]`), present in the interpreter shown above.
No jobs are submitted automatically.

Large files default to `/scratch/$USER/avant-garde-reproduction`:

- `huggingface/`: checkpoints, tokenizers and Hub cache
- `datasets/`: processed datasets
- `tmp/$SLURM_JOB_ID/`: temporary files
- `runs/smoke-$SLURM_JOB_ID/`: JSON results

Set `AVANT_GARDE_DATA_ROOT` to change the root; `AVANT_GARDE_SCRATCH` remains a
compatible override when the new variable is unset. Slurm logs are written to
`slurm-avant-garde-smoke-JOBID.out` in the submission directory. Scratch is
disposable; copy valuable reports to durable storage. The environment and
repository must be accessible on compute nodes. Add cluster-specific account or
QoS submission flags if required.

The default job downloads public models and WikiText-2 into scratch. With caches
prepopulated, export `AVANT_GARDE_OFFLINE=1` before submission. Missing cache
entries or network access fail explicitly; no substitute dataset is used.
Pin `--revision` and `--dataset-revision` for repeatable follow-up downloads.
Actual checkpoint commits and dataset fingerprints are saved.

## Follow-up experiments (inside GPU allocations)

The model-size sweep runs GPT-2 Small/Medium/Large/XL at context 128 with 256
WikiText-2 windows each, then ViT Base/Large on the same class-balanced 1,000-image
ImageNet validation subset fetched from Hugging Face. Account `cs471`, six CPUs,
32 GB, one L40S, and four hours are requested. Submit from the repository root:

```bash
export AVANT_GARDE_PYTHON=/home/santanto/miniconda3/envs/nanofm/bin/python
sbatch scripts/slurm/model_size_l40s.sbatch
```

No local ImageNet manifest is needed: the job downloads only official validation
shards at the pinned revision and creates a reusable subset with `source.json`.
Alternatively set `AVANT_GARDE_IMAGENET_MANIFEST` to an existing CSV. Use
`AVANT_GARDE_FAMILIES=gpt2` or `vit` to select one family; the default is `both`.
Results and a combined normalized bar graph go into `runs/size-JOBID/` under the
data root. Storage stays on scratch for now; set `AVANT_GARDE_DATA_ROOT` to move
to a writable work directory later. Temporary files stay on scratch.

The [first smoke run](docs/smoke-4828405.md) completed on L40S and recorded a
flattening penalty with zero flattening overflows. Larger sweeps test whether
that degradation changes with model size.

To rerun only ViT while including completed GPT-2 results in the combined plot,
set `AVANT_GARDE_FAMILIES=vit` and `AVANT_GARDE_GPT2_RESULTS` to the earlier
run's `gpt2/` directory before submission. The script now produces graphs of
completed reports on exit even if a later stage fails. Existing login credentials
are preserved through `HF_TOKEN_PATH` when relocating the Hub cache.

Other configurations can be run inside GPU allocations:

```bash
"$AVANT_GARDE_PYTHON" -m avant_garde.cli gpt2 --device cuda \
  --context 512 --windows 32 --output "$AVANT_GARDE_SCRATCH/runs/gpt2-512.json"
"$AVANT_GARDE_PYTHON" -m avant_garde.cli sweep \
  --config configs/gpt2_size_context.json --device cuda \
  --output-dir "$AVANT_GARDE_SCRATCH/runs/gpt2-sweep"
"$AVANT_GARDE_PYTHON" -m avant_garde.cli sweep \
  --config configs/vit_size.json --device cuda \
  --output-dir "$AVANT_GARDE_SCRATCH/runs/vit-sweep" \
  --extra --manifest /scratch/USER/imagenet/validation.csv
```

Sweeps run sequentially and stop on failure; the smoke allocation is not sized
for full sweeps. Use `--text-file PATH` for local Wikipedia text, `--weights-only`
to isolate weights, and `--rounding nearest` or `--rounding trunc` for sensitivity.

Supply ImageNet locally via CSV with `path,label` columns. Paths may be absolute
or relative to the manifest; labels must match zero-based checkpoint class IDs.
Alphabetical folder order is not inferred.

```csv
path,label
val/n01440764/ILSVRC2012_val_00000293.JPEG,0
```

Export paired differences and normalized grouped bar graphs from completed reports:

```bash
"$AVANT_GARDE_PYTHON" -m avant_garde.summarize \
  /scratch/USER/avant-garde-reproduction/runs/gpt2-sweep/*.json \
  --csv /scratch/USER/avant-garde-reproduction/runs/comparison.csv \
  --plot /scratch/USER/avant-garde-reproduction/runs/comparison.png
```

Bars show FP32 (unquantized), MX9 (not flattened), and MX9 (flattened), divided
by each experiment's FP32 metric. FP32 is 1. Perplexity and top-1 accuracy have
separate panels: lower perplexity is better; higher accuracy is better. The CSV
includes `normalized_to_fp32` alongside raw values and degradation measures.
The lossless control stays in the CSV but is omitted from the bars. A zero FP32
baseline produces N/A rather than an invented ratio. Plot labels indicate whether
the experiment quantizes weights only or weights and activations.

Reports include metrics, versions, settings, coverage and separate quantization/
flattening diagnostics. Lossless flattening should match hierarchical MX9
exactly. Default 8-bit flattening can lose rounding precision, while flattening
overflow should be zero. Accuracy degradation is an outcome, not a test failure.

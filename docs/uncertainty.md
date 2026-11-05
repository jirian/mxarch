# Uncertainty and the context-length experiment

Every new GPT-2 and ViT evaluation saves individual observations and estimates
uncertainty using 1,000 nonparametric bootstrap replicates, seed 0 by default.
Set `--bootstrap-replicates` and `--seed` to change these settings.

For GPT-2, randomly resample whole text windows with replacement. For each
replicate, sum their next-token losses and token counts, then compute
`exp(total loss / total scored tokens)`. This preserves the token-weighted
perplexity definition; it does not average individual windows' perplexities.
For ViT, resample individual images and recompute top-1/top-5 accuracy.

The reported SD is the sample standard deviation of these replicate metrics.
It estimates sensitivity to evaluation-sample selection, conditional on the
observed data. It is not variation across training seeds or a 95% confidence
interval. Whole-window resampling preserves dependencies within a text window;
independence between windows is an approximation. Image resampling is an
approximation for the class-balanced ImageNet pilot, with only one image per
class; it cannot recover unobserved within-class variability.

Numerical modes share the same resampled indices. For normalized error bars,
divide each replicate's metric by that replicate's FP32 metric, then compute
the SD of the resulting ratios. This accounts for the shared examples and gives
the FP32 baseline a normalized SD of zero. It does not simply divide an absolute
SD by the original baseline. If any replicate has zero FP32 accuracy, normalized
SD is undefined and omitted; the report records how many such replicates occurred.
Raw accuracy uncertainty remains available.

JSON `uncertainty` fields record method, unit, observation count, seed, replicate
count, raw metric SD and normalized SD. Raw observations are in
`metrics.observations`. CSV exports `std` and `normalized_std`. Graphs show
**±1 bootstrap SD**, with separate perplexity and accuracy panels. Old reports
without observations cannot gain SD retrospectively; they remain plottable
without error bars and require reevaluation for uncertainty estimates.

## Context sweep

The requested values refer to tokens per sequence, not inference batch size.
Pretrained GPT-2 supports at most 1,024 positions. The configuration therefore
uses **128, 512, 1024**, replacing the unsupported requested 2048 with 1024.
It never silently truncates 2048 or extends learned position embeddings.

`configs/gpt2_context.json` evaluates all four GPT-2 sizes on the same first
32,768 input tokens: 256 windows at context 128, 64 at 512, 32 at 1024.
Inference still uses one sequence at a time. Because each independent window
omits prediction of its first token, scored transitions are 32,512, 32,704,
and 32,736 respectively. All modes at each context score identical transitions.
Contexts have different bootstrap window units/counts; this is intentional and
should be considered when interpreting their error-bar widths.

Submit from the repository root after CPU checks:

```bash
export AVANT_GARDE_PYTHON=/home/santanto/miniconda3/envs/nanofm/bin/python
sbatch scripts/slurm/gpt2_context_l40s.sbatch
```

The script uses account cs471, one L40S, six CPUs, 32 GB and four hours. It saves
reports and normalized bars under the scratch data root's `runs/context-JOBID/`.
New ViT evaluations automatically include accuracy SD with the existing runner.

#!/bin/bash
#SBATCH --account=cs471
#SBATCH --job-name=avant-garde-eval-rounding
#SBATCH --partition=h100
#SBATCH --gres=gpu:nvidia_h100:1
#SBATCH --cpus-per-task=12
#SBATCH --mem=64G
#SBATCH --time=06:00:00
#SBATCH --output=/work/cs-471/mixedprecisionarchitects/avant-garde/runs/slurm-%x-%j.out

# Is truncating flattening's Qwen3-8B perplexity drop real or an artifact of the
# Wikipedia evaluation text? Same settings as the grid (MX9 conversion nearest,
# FP32 activations, dequantized backend), on
#  1. a second text: WikiText-2 validation (context 2048, 64 windows), and
#  2. multiple-choice accuracy: ARC-Challenge test (1172) and HellaSwag
#     validation (1000, seed 0), FP32 / hierarchical / flattened nearest / trunc.
set -euo pipefail
BASE=/work/cs-471/mixedprecisionarchitects/avant-garde
export AVANT_GARDE_PYTHON="$BASE/venv-qwen/bin/python"
export AVANT_GARDE_DATA_ROOT="$BASE/data" AVANT_GARDE_TMP_ROOT="$BASE/tmp" AVANT_GARDE_OFFLINE=1
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
cd "${SLURM_SUBMIT_DIR:?Submit using sbatch from repo-merge}"
source scripts/slurm/environment.sh
RUN_DIR="$BASE/runs/eval-rounding-${SLURM_JOB_ID}"
mkdir -p "$RUN_DIR"
cp MERGE_COMMIT "$RUN_DIR/git-commit.txt"
EVAL="$BASE/data/eval"
ppl() { "$AVANT_GARDE_PYTHON" -m avant_garde.cli gpt2 --device cuda --offline \
            --text-file "$EVAL/wikitext-2-raw-v1-validation.txt" --model Qwen/Qwen3-8B \
            --context 2048 --windows 64 --rounding nearest --backend dequantized \
            --activation-policy fp32 "$@"; }
mc() { "$AVANT_GARDE_PYTHON" scripts/mc_eval.py --model Qwen/Qwen3-8B \
            --task arc=$EVAL/arc-challenge-test.jsonl --task hellaswag=$EVAL/hellaswag-validation-1000.jsonl \
            --config fp32=fp32:trunc hier=mx9_hierarchical:trunc \
                     flat-nearest=mx9_flattened:nearest flat-trunc=mx9_flattened:trunc "$@"; }

# Fail fast and time the multiple-choice loop on 20 questions per task.
mc --limit 20 --output "$RUN_DIR/mc-check.json"
ppl --modes fp32 mx9_hierarchical mx9_flattened --flatten-rounding nearest \
    --output "$RUN_DIR/wikitext-flat-nearest.json"
ppl --modes mx9_hierarchical mx9_flattened --flatten-rounding trunc \
    --output "$RUN_DIR/wikitext-flat-trunc.json"
mc --output "$RUN_DIR/mc.json"
printf 'Results: %s\n' "$RUN_DIR"

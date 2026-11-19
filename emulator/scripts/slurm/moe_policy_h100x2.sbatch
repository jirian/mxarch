#!/bin/bash
#SBATCH --account=cs471
#SBATCH --job-name=avant-garde-moe-policy
#SBATCH --partition=h100
#SBATCH --gres=gpu:nvidia_h100:2
#SBATCH --cpus-per-task=12
#SBATCH --mem=64G
#SBATCH --time=02:00:00
#SBATCH --output=/work/cs-471/mixedprecisionarchitects/avant-garde/runs/slurm-%x-%j.out

# H1.1 validation on Qwen3-30B-A3B: static flattening policy chosen from the
# group breakdown (moe-rounding-5008245, ranked on even windows): flatten the
# experts and router, keep attention projections, attention products and the
# LM head as hierarchical MX9. Same protocol (Wikipedia, context 2048,
# 16 windows); the summary also reports the held-out odd windows.
set -euo pipefail
BASE=/work/cs-471/mixedprecisionarchitects/avant-garde
export AVANT_GARDE_PYTHON="$BASE/venv-qwen/bin/python"
export AVANT_GARDE_DATA_ROOT="$BASE/data" AVANT_GARDE_TMP_ROOT="$BASE/tmp" AVANT_GARDE_OFFLINE=1
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
cd "${SLURM_SUBMIT_DIR:?Submit using sbatch from repo-merge}"
source scripts/slurm/environment.sh
RUN_DIR="$BASE/runs/moe-policy-${SLURM_JOB_ID}"
mkdir -p "$RUN_DIR"
cp MERGE_COMMIT "$RUN_DIR/git-commit.txt"
TEXT="$BASE/data/text/wikipedia-20231101-en-150.txt"
KEEP='self_attn(\.(q|k|v|o)_proj)?$|^lm_head$'
for rnd in nearest trunc; do
    "$AVANT_GARDE_PYTHON" -m avant_garde.cli gpt2 --device cuda --offline --text-file "$TEXT" \
        --model Qwen/Qwen3-30B-A3B --device-map auto --no-weight-cache --context 2048 --windows 16 \
        --rounding nearest --backend dequantized --activation-policy fp32 --flatten-rounding "$rnd" \
        --modes mx9_hierarchical mx9_flattened --exempt "$KEEP" --exempt-mode mx9_hierarchical \
        --output "$RUN_DIR/policy-experts-router-flat-$rnd.json"
done
printf 'Results: %s\n' "$RUN_DIR"

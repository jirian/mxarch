#!/bin/bash
#SBATCH --account=cs471
#SBATCH --job-name=avant-garde-moe-rounding
#SBATCH --partition=h100
#SBATCH --gres=gpu:nvidia_h100:2
#SBATCH --cpus-per-task=12
#SBATCH --mem=64G
#SBATCH --time=05:00:00
#SBATCH --output=/work/cs-471/mixedprecisionarchitects/avant-garde/runs/slurm-%x-%j.out

# Qwen3-30B-A3B (MoE), status-report protocol (Wikipedia text, context 2048,
# 16 windows), MX9 conversion nearest, FP32 activations, dequantized backend.
#  1. Flattening rounding: nearest vs trunc (all GEMMs flattened).
#  2. H1.1 group breakdown: hierarchical MX9 everywhere except ONE group that is
#     flattened, for each rounding. Groups partition every GEMM: attention
#     projections, attention products, router, experts, LM head. Per-window
#     losses allow ranking on half of the windows and validating on the other.
set -euo pipefail
BASE=/work/cs-471/mixedprecisionarchitects/avant-garde
export AVANT_GARDE_PYTHON="$BASE/venv-qwen/bin/python"
export AVANT_GARDE_DATA_ROOT="$BASE/data" AVANT_GARDE_TMP_ROOT="$BASE/tmp" AVANT_GARDE_OFFLINE=1
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
cd "${SLURM_SUBMIT_DIR:?Submit using sbatch from repo-merge}"
source scripts/slurm/environment.sh
RUN_DIR="$BASE/runs/moe-rounding-${SLURM_JOB_ID}"
mkdir -p "$RUN_DIR"
cp MERGE_COMMIT "$RUN_DIR/git-commit.txt"
TEXT="$BASE/data/text/wikipedia-20231101-en-150.txt"
run() { "$AVANT_GARDE_PYTHON" -m avant_garde.cli gpt2 --device cuda --offline --text-file "$TEXT" \
            --model Qwen/Qwen3-30B-A3B --device-map auto --no-weight-cache --context 2048 --windows 16 \
            --rounding nearest --backend dequantized --activation-policy fp32 "$@"; }

run --modes mx9_hierarchical mx9_flattened --flatten-rounding nearest --output "$RUN_DIR/all-flat-nearest.json"
run --modes mx9_hierarchical mx9_flattened --flatten-rounding trunc --output "$RUN_DIR/all-flat-trunc.json"
declare -A GROUPS=(
    [attn-proj]='self_attn\.(q|k|v|o)_proj$'
    [attn-products]='self_attn$'
    [router]='mlp\.gate$'
    [experts]='mlp\.experts\.'
    [lm-head]='^lm_head$'
)
for rnd in nearest trunc; do
    for g in attn-proj attn-products router experts lm-head; do
        run --modes mx9_hierarchical --exempt "${GROUPS[$g]}" --exempt-mode mx9_flattened \
            --flatten-rounding "$rnd" --output "$RUN_DIR/only-$g-flat-$rnd.json"
    done
done
printf 'Results: %s\n' "$RUN_DIR"

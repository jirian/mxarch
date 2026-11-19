#!/bin/bash
#SBATCH --account=cs471
#SBATCH --job-name=avant-garde-moe-groups
#SBATCH --partition=h100
#SBATCH --gres=gpu:nvidia_h100:2
#SBATCH --cpus-per-task=12
#SBATCH --mem=64G
#SBATCH --time=04:00:00
#SBATCH --output=/work/cs-471/mixedprecisionarchitects/avant-garde/runs/slurm-%x-%j.out

# H1.1 group breakdown on Qwen3-30B-A3B, completing moe-rounding-5008245 (whose
# full-flattening runs finished; its group stage failed on a bash name clash).
# Hierarchical MX9 everywhere except ONE flattened group, for each rounding.
# Results go to the same directory so moe_groups_summary.py sees one set.
set -euo pipefail
BASE=/work/cs-471/mixedprecisionarchitects/avant-garde
export AVANT_GARDE_PYTHON="$BASE/venv-qwen/bin/python"
export AVANT_GARDE_DATA_ROOT="$BASE/data" AVANT_GARDE_TMP_ROOT="$BASE/tmp" AVANT_GARDE_OFFLINE=1
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
cd "${SLURM_SUBMIT_DIR:?Submit using sbatch from repo-merge}"
source scripts/slurm/environment.sh
RUN_DIR="$BASE/runs/moe-rounding-5008245"
TEXT="$BASE/data/text/wikipedia-20231101-en-150.txt"
run() { "$AVANT_GARDE_PYTHON" -m avant_garde.cli gpt2 --device cuda --offline --text-file "$TEXT" \
            --model Qwen/Qwen3-30B-A3B --device-map auto --no-weight-cache --context 2048 --windows 16 \
            --rounding nearest --backend dequantized --activation-policy fp32 "$@"; }
# GROUPS is a reserved bash variable; use a different name.
declare -A GROUP_RX=(
    [attn-proj]='self_attn\.(q|k|v|o)_proj$'
    [attn-products]='self_attn$'
    [router]='mlp\.gate$'
    [experts]='mlp\.experts\.'
    [lm-head]='^lm_head$'
)
for rnd in nearest trunc; do
    for g in attn-proj attn-products router experts lm-head; do
        run --modes mx9_hierarchical --exempt "${GROUP_RX[$g]}" --exempt-mode mx9_flattened \
            --flatten-rounding "$rnd" --output "$RUN_DIR/only-$g-flat-$rnd.json"
    done
done
printf 'Results: %s\n' "$RUN_DIR"

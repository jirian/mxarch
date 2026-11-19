#!/bin/bash
#SBATCH --account=cs471
#SBATCH --job-name=avant-garde-grid-gpt2
#SBATCH --partition=l40s
#SBATCH --gres=gpu:nvidia_l40s:1
#SBATCH --cpus-per-task=6
#SBATCH --mem=32G
#SBATCH --time=04:00:00
#SBATCH --output=/work/cs-471/mixedprecisionarchitects/avant-garde/runs/slurm-%x-%j.out

# 2x2 grid on the status-report text and windows (context 1024, 64 windows):
# flattening rounding {nearest, trunc} x activation policy {fp32, hierarchical},
# GPT-2 S/M/L/XL, MX9 conversion rounding nearest, dequantized backend.
# Each run pairs flattened with hierarchical MX9 under the same activations.
# Backend check: GPT-2 Small, trunc + hierarchical, Figure 8 vs dequantized.
set -euo pipefail
BASE=/work/cs-471/mixedprecisionarchitects/avant-garde
export AVANT_GARDE_PYTHON="$BASE/venv-qwen/bin/python"
export AVANT_GARDE_DATA_ROOT="$BASE/data" AVANT_GARDE_TMP_ROOT="$BASE/tmp" AVANT_GARDE_OFFLINE=1
cd "${SLURM_SUBMIT_DIR:?Submit using sbatch from repo-merge}"
source scripts/slurm/environment.sh
RUN_DIR="$BASE/runs/grid-gpt2-${SLURM_JOB_ID}"
mkdir -p "$RUN_DIR"
cp MERGE_COMMIT "$RUN_DIR/git-commit.txt"
TEXT="$BASE/data/text/wikipedia-20231101-en-150.txt"
run() { "$AVANT_GARDE_PYTHON" -m avant_garde.cli gpt2 --device cuda --offline --text-file "$TEXT" \
            --context 1024 --windows 64 --rounding nearest "$@"; }

for model in gpt2 gpt2-medium gpt2-large gpt2-xl; do
    M="openai-community/$model"
    run --model "$M" --modes fp32 --activation-policy fp32 --output "$RUN_DIR/$model-fp32.json"
    for act in fp32 hierarchical; do
        for rnd in nearest trunc; do
            run --model "$M" --modes mx9_hierarchical mx9_flattened --backend dequantized \
                --activation-policy "$act" --flatten-rounding "$rnd" \
                --output "$RUN_DIR/$model-act-$act-flat-$rnd.json"
        done
    done
done
run --model openai-community/gpt2 --modes mx9_hierarchical mx9_flattened --backend figure8 \
    --activation-policy hierarchical --flatten-rounding trunc \
    --output "$RUN_DIR/gpt2-act-hierarchical-flat-trunc-figure8.json"
printf 'Results: %s\n' "$RUN_DIR"

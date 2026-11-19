#!/bin/bash
#SBATCH --account=cs471
#SBATCH --job-name=avant-garde-grid-qwen3
#SBATCH --partition=h100
#SBATCH --gres=gpu:nvidia_h100:1
#SBATCH --cpus-per-task=12
#SBATCH --mem=64G
#SBATCH --time=05:00:00
#SBATCH --output=/work/cs-471/mixedprecisionarchitects/avant-garde/runs/slurm-%x-%j.out

# 2x2 grid for Qwen3-8B on the status-report protocol (context 2048, 64 windows):
# flattening rounding {nearest, trunc} x activation policy {fp32, hierarchical},
# MX9 conversion rounding nearest, dequantized backend. A 4-window Figure 8 run
# checks that the backend does not change the trunc + fp32 result.
set -euo pipefail
BASE=/work/cs-471/mixedprecisionarchitects/avant-garde
export AVANT_GARDE_PYTHON="$BASE/venv-qwen/bin/python"
export AVANT_GARDE_DATA_ROOT="$BASE/data" AVANT_GARDE_TMP_ROOT="$BASE/tmp" AVANT_GARDE_OFFLINE=1
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
cd "${SLURM_SUBMIT_DIR:?Submit using sbatch from repo-merge}"
source scripts/slurm/environment.sh
RUN_DIR="$BASE/runs/grid-qwen3-${SLURM_JOB_ID}"
mkdir -p "$RUN_DIR"
cp MERGE_COMMIT "$RUN_DIR/git-commit.txt"
TEXT="$BASE/data/text/wikipedia-20231101-en-150.txt"
run() { "$AVANT_GARDE_PYTHON" -m avant_garde.cli gpt2 --device cuda --offline --text-file "$TEXT" \
            --model Qwen/Qwen3-8B --context 2048 --rounding nearest "$@"; }

# Fail fast on the new Qwen3 hierarchical-activation boundaries.
run --windows 1 --bootstrap-replicates 10 --modes mx9_flattened --backend dequantized \
    --activation-policy hierarchical --output "$RUN_DIR/check-hierarchical.json"
for act in fp32 hierarchical; do
    for rnd in nearest trunc; do
        run --windows 64 --modes mx9_hierarchical mx9_flattened --backend dequantized \
            --activation-policy "$act" --flatten-rounding "$rnd" \
            --output "$RUN_DIR/qwen3-8b-act-$act-flat-$rnd.json"
    done
done
for backend in dequantized figure8; do
    run --windows 4 --modes mx9_hierarchical mx9_flattened --backend "$backend" \
        --activation-policy fp32 --flatten-rounding trunc \
        --output "$RUN_DIR/qwen3-8b-w4-act-fp32-flat-trunc-$backend.json"
done
printf 'Results: %s\n' "$RUN_DIR"

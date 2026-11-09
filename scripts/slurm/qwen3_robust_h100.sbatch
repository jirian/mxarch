#!/bin/bash
#SBATCH --account=cs471
#SBATCH --job-name=avant-garde-qwen3-robust
#SBATCH --partition=h100
#SBATCH --gres=gpu:nvidia_h100:1
#SBATCH --cpus-per-task=12
#SBATCH --mem=64G
#SBATCH --time=04:00:00
#SBATCH --output=/work/cs-471/mixedprecisionarchitects/avant-garde/runs/slurm-%x-%j.out

# Qwen3-8B H1 robustness: 4x the text at context 2048 (64 windows), and context 8192
# (16 windows, same 131k tokens). At 8192 the weight cache is off to fit attention.
set -euo pipefail
BASE=/work/cs-471/mixedprecisionarchitects/avant-garde
export AVANT_GARDE_PYTHON="$BASE/venv-qwen/bin/python"
export AVANT_GARDE_DATA_ROOT="$BASE/data" AVANT_GARDE_TMP_ROOT="$BASE/tmp" AVANT_GARDE_OFFLINE=1
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
cd "${SLURM_SUBMIT_DIR:?Submit using sbatch from the repository root}"
source scripts/slurm/environment.sh
RUN_DIR="$BASE/runs/qwen3-robust-${SLURM_JOB_ID}"
mkdir -p "$RUN_DIR"
TEXT="$BASE/data/text/wikipedia-20231101-en-150.txt"
git rev-parse HEAD > "$RUN_DIR/git-commit.txt"; git status --short >> "$RUN_DIR/git-commit.txt"
run() { "$AVANT_GARDE_PYTHON" -m avant_garde.cli gpt2 --device cuda --offline --text-file "$TEXT" \
            --model Qwen/Qwen3-8B --rounding nearest "$@"; }

run --context 8192 --windows 1 --no-weight-cache --bootstrap-replicates 10 \
    --modes mx9_flattened --output "$RUN_DIR/check-ctx8192.json"
run --context 2048 --windows 64 --modes fp32 mx9_hierarchical mx9_flattened \
    --output "$RUN_DIR/ctx2048-w64-all.json"
run --context 2048 --windows 64 --modes mx9_flattened --exempt '^lm_head$' \
    --output "$RUN_DIR/ctx2048-w64-all-head-hier.json"
run --context 8192 --windows 16 --no-weight-cache --modes fp32 mx9_hierarchical mx9_flattened \
    --output "$RUN_DIR/ctx8192-w16-all.json"
run --context 8192 --windows 16 --no-weight-cache --modes mx9_flattened --exempt '^lm_head$' \
    --output "$RUN_DIR/ctx8192-w16-all-head-hier.json"
printf 'Results: %s\n' "$RUN_DIR"

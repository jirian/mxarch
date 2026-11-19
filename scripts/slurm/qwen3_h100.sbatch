#!/bin/bash
#SBATCH --account=cs471
#SBATCH --job-name=avant-garde-qwen3
#SBATCH --partition=h100
#SBATCH --gres=gpu:nvidia_h100:1
#SBATCH --cpus-per-task=12
#SBATCH --mem=64G
#SBATCH --time=04:00:00
#SBATCH --output=/work/cs-471/mixedprecisionarchitects/avant-garde/runs/slurm-%x-%j.out

# H1 on Qwen3-8B: hierarchical vs flattened MX9, with and without LM-head fallback.
# Same Wikipedia text as the GPT-2 runs; context 2048, 16 windows (32,752 scored tokens).
# Needs transformers >= 4.51 (venv-qwen). FP32 weights + cached dequantized weights ~66 GB.
set -euo pipefail
BASE=/work/cs-471/mixedprecisionarchitects/avant-garde
export AVANT_GARDE_PYTHON="$BASE/venv-qwen/bin/python"
export AVANT_GARDE_DATA_ROOT="$BASE/data"
export AVANT_GARDE_TMP_ROOT="$BASE/tmp"
export AVANT_GARDE_OFFLINE=1
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
cd "${SLURM_SUBMIT_DIR:?Submit using sbatch from the repository root}"
source scripts/slurm/environment.sh
RUN_DIR="$BASE/runs/qwen3-${SLURM_JOB_ID}"
mkdir -p "$RUN_DIR"
TEXT="$BASE/data/text/wikipedia-20231101-en-150.txt"
git rev-parse HEAD > "$RUN_DIR/git-commit.txt"; git status --short >> "$RUN_DIR/git-commit.txt"
run() { "$AVANT_GARDE_PYTHON" -m avant_garde.cli gpt2 --device cuda --offline --text-file "$TEXT" \
            --model Qwen/Qwen3-8B --rounding nearest "$@"; }

# 0. Fail fast: loading, coverage, memory.
run --context 512 --windows 1 --bootstrap-replicates 10 --modes fp32 mx9_flattened \
    --output "$RUN_DIR/check.json"
nvidia-smi --query-gpu=memory.used,memory.total --format=csv
# 1. Main comparison, all GEMM operands.
run --context 2048 --windows 16 --modes fp32 mx9_hierarchical mx9_flattened \
    --output "$RUN_DIR/ctx2048-all.json"
# 2. LM head kept non-flattened (H1.1 fallback found on GPT-2).
run --context 2048 --windows 16 --modes mx9_flattened --exempt '^lm_head$' \
    --output "$RUN_DIR/ctx2048-all-head-hier.json"
# 3. Weights only.
run --context 2048 --windows 16 --weights-only --modes mx9_hierarchical mx9_flattened \
    --output "$RUN_DIR/ctx2048-weights.json"
printf 'Results: %s\n' "$RUN_DIR"

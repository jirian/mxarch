#!/bin/bash
#SBATCH --account=cs471
#SBATCH --job-name=avant-garde-qwen3-moe
#SBATCH --partition=h100
#SBATCH --gres=gpu:nvidia_h100:2
#SBATCH --cpus-per-task=12
#SBATCH --mem=64G
#SBATCH --time=04:00:00
#SBATCH --output=/work/cs-471/mixedprecisionarchitects/avant-garde/runs/slurm-%x-%j.out

# H1 on the MoE model Qwen3-30B-A3B (128 experts, 8 active). FP32 emulation needs
# ~122 GB of weights: spread over two H100s, weights re-quantized per use (no cache).
set -euo pipefail
BASE=/work/cs-471/mixedprecisionarchitects/avant-garde
export AVANT_GARDE_PYTHON="$BASE/venv-qwen/bin/python"
export AVANT_GARDE_DATA_ROOT="$BASE/data" AVANT_GARDE_TMP_ROOT="$BASE/tmp" AVANT_GARDE_OFFLINE=1
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
cd "${SLURM_SUBMIT_DIR:?Submit using sbatch from the repository root}"
source scripts/slurm/environment.sh
RUN_DIR="$BASE/runs/qwen3-moe-${SLURM_JOB_ID}"
mkdir -p "$RUN_DIR"
TEXT="$BASE/data/text/wikipedia-20231101-en-150.txt"
git rev-parse HEAD > "$RUN_DIR/git-commit.txt"; git status --short >> "$RUN_DIR/git-commit.txt"
run() { "$AVANT_GARDE_PYTHON" -m avant_garde.cli gpt2 --device cuda --offline --text-file "$TEXT" \
            --model Qwen/Qwen3-30B-A3B --device-map auto --no-weight-cache --rounding nearest "$@"; }

run --context 512 --windows 1 --bootstrap-replicates 10 --modes fp32 mx9_flattened \
    --output "$RUN_DIR/check.json"
nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv
run --context 2048 --windows 16 --modes fp32 mx9_hierarchical mx9_flattened \
    --output "$RUN_DIR/ctx2048-all.json"
run --context 2048 --windows 16 --modes mx9_flattened --exempt '^lm_head$' \
    --output "$RUN_DIR/ctx2048-all-head-hier.json"
printf 'Results: %s\n' "$RUN_DIR"

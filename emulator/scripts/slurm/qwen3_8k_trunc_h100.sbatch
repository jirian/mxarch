#!/bin/bash
#SBATCH --account=cs471
#SBATCH --job-name=avant-garde-qwen3-8k-trunc
#SBATCH --partition=h100
#SBATCH --gres=gpu:nvidia_h100:1
#SBATCH --cpus-per-task=12
#SBATCH --mem=64G
#SBATCH --time=02:00:00
#SBATCH --output=/work/cs-471/mixedprecisionarchitects/avant-garde/runs/slurm-%x-%j.out

# Qwen3-8B at context 8192 (16 windows, status-report protocol) with truncating
# flattening, completing the 2k/8k comparison of the rounding grid. Weight cache
# off to fit 8k attention, as in qwen3-robust.
set -euo pipefail
BASE=/work/cs-471/mixedprecisionarchitects/avant-garde
export AVANT_GARDE_PYTHON="$BASE/venv-qwen/bin/python"
export AVANT_GARDE_DATA_ROOT="$BASE/data" AVANT_GARDE_TMP_ROOT="$BASE/tmp" AVANT_GARDE_OFFLINE=1
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
cd "${SLURM_SUBMIT_DIR:?Submit using sbatch from repo-merge}"
source scripts/slurm/environment.sh
RUN_DIR="$BASE/runs/qwen3-8k-trunc-${SLURM_JOB_ID}"
mkdir -p "$RUN_DIR"
cp MERGE_COMMIT "$RUN_DIR/git-commit.txt"
"$AVANT_GARDE_PYTHON" -m avant_garde.cli gpt2 --device cuda --offline \
    --text-file "$BASE/data/text/wikipedia-20231101-en-150.txt" --model Qwen/Qwen3-8B \
    --context 8192 --windows 16 --no-weight-cache --rounding nearest --backend dequantized \
    --activation-policy fp32 --modes mx9_hierarchical mx9_flattened --flatten-rounding trunc \
    --output "$RUN_DIR/ctx8192-flat-trunc.json"
printf 'Results: %s\n' "$RUN_DIR"

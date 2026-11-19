#!/bin/bash
#SBATCH --account=cs471
#SBATCH --job-name=avant-garde-h3-fused
#SBATCH --partition=h100
#SBATCH --gres=gpu:nvidia_h100:1
#SBATCH --cpus-per-task=12
#SBATCH --mem=64G
#SBATCH --time=00:45:00
#SBATCH --output=/work/cs-471/mixedprecisionarchitects/avant-garde/runs/slurm-%x-%j.out

# H3 with fused attention (SDPA / FlashAttention), as used in production
# serving, at 8k and 32k. The earlier eager profile (acc-h3-qwen3-5009656)
# timed an unfused FP32 softmax, which overstates the residual work.
set -euo pipefail
BASE=/work/cs-471/mixedprecisionarchitects/avant-garde
export AVANT_GARDE_PYTHON="$BASE/venv-qwen/bin/python"
export AVANT_GARDE_DATA_ROOT="$BASE/data" AVANT_GARDE_TMP_ROOT="$BASE/tmp" AVANT_GARDE_OFFLINE=1
cd "${SLURM_SUBMIT_DIR:?Submit using sbatch from repo-merge}"
source scripts/slurm/environment.sh
RUN_DIR="$BASE/runs/h3-fused-${SLURM_JOB_ID}"
mkdir -p "$RUN_DIR"
cp MERGE_COMMIT "$RUN_DIR/git-commit.txt"
"$AVANT_GARDE_PYTHON" scripts/h3_layer_profile.py --model Qwen/Qwen3-8B --attention fused \
    --output "$RUN_DIR/h3-layer-profile-fused.json"
printf 'Results: %s\n' "$RUN_DIR"

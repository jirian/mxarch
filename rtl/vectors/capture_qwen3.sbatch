#!/usr/bin/env bash
#SBATCH --job-name=ag-capture-qwen3
#SBATCH --account=cs471
#SBATCH --partition=h100
#SBATCH --gres=gpu:nvidia_h100:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=46G
#SBATCH --time=00:30:00
#SBATCH --output=slurm-ag-capture-qwen3-%j.out
# One 512-token forward pass of Qwen3-8B (BF16) to capture real MX9 operand blocks.
set -euo pipefail
BASE=/work/cs-471/mixedprecisionarchitects/avant-garde
export AVANT_GARDE_PYTHON="$BASE/venv-qwen/bin/python"
export AVANT_GARDE_DATA_ROOT="$BASE/data"
export AVANT_GARDE_TMP_ROOT="$BASE/tmp"
export HF_HUB_OFFLINE=1
cd "$BASE/repo"
source scripts/slurm/environment.sh
cd "$BASE/tmp/rtl"
PYTHONPATH="$BASE/repo:$PWD" "$AVANT_GARDE_PYTHON" capture_qwen3.py \
  --text-file "$BASE/data/text/wikipedia-20231101-en-150.txt"

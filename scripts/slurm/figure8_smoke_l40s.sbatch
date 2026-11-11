#!/bin/bash
#SBATCH --account=cs471
#SBATCH --job-name=avant-garde-figure8-smoke
#SBATCH --partition=l40s
#SBATCH --gres=gpu:nvidia_l40s:1
#SBATCH --cpus-per-task=6
#SBATCH --mem=32G
#SBATCH --time=01:00:00
#SBATCH --output=slurm-%x-%j.out

set -euo pipefail
: "${AVANT_GARDE_PYTHON:?Set AVANT_GARDE_PYTHON to the environment python executable}"
cd "${SLURM_SUBMIT_DIR:?Submit from the repository root}"
source scripts/slurm/environment.sh
RUN_DIR="$AVANT_GARDE_DATA_ROOT/runs/figure8-smoke-${SLURM_JOB_ID}"
mkdir -p "$RUN_DIR"

"$AVANT_GARDE_PYTHON" -c 'import torch; assert torch.cuda.is_available(); print(torch.cuda.get_device_name())'
AVANT_GARDE_TEST_CUDA=1 "$AVANT_GARDE_PYTHON" -m pytest tests/test_tensor_core.py tests/test_activations.py -q
"$AVANT_GARDE_PYTHON" -m avant_garde.cli smoke-vit --device cuda \
    --backend figure8 --exponent-overflow wide --flatten-rounding trunc --activation-policy hierarchical \
    --output "$RUN_DIR/vit-smoke.json" "${offline[@]}"
"$AVANT_GARDE_PYTHON" -m avant_garde.cli gpt2 --device cuda \
    --backend figure8 --exponent-overflow wide --flatten-rounding trunc --activation-policy hierarchical \
    --context 128 --windows 2 \
    --output "$RUN_DIR/gpt2-smoke.json" "${offline[@]}"
"$AVANT_GARDE_PYTHON" -m avant_garde.summarize "$RUN_DIR/gpt2-smoke.json" \
    --csv "$RUN_DIR/comparison.csv" --plot "$RUN_DIR/comparison.png"
printf 'Figure 8 smoke results: %s\n' "$RUN_DIR"

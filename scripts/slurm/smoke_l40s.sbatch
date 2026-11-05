#!/bin/bash
#SBATCH --account=cs471
#SBATCH --job-name=avant-garde-smoke
#SBATCH --partition=l40s
#SBATCH --gres=gpu:nvidia_l40s:1
#SBATCH --cpus-per-task=6
#SBATCH --mem=32G
#SBATCH --time=01:00:00
#SBATCH --output=slurm-%x-%j.out

set -euo pipefail

# Submit from the repository root. Use the environment's interpreter directly;
# no interactive shell or conda activation is needed on the compute node.
: "${AVANT_GARDE_PYTHON:?Set AVANT_GARDE_PYTHON to the environment python executable}"
cd "${SLURM_SUBMIT_DIR:?Submit using sbatch from the repository root}"
source scripts/slurm/environment.sh
RUN_DIR="$AVANT_GARDE_DATA_ROOT/runs/smoke-${SLURM_JOB_ID}"
mkdir -p "$RUN_DIR"

"$AVANT_GARDE_PYTHON" -c 'import torch, transformers, datasets, PIL, numpy, matplotlib; assert torch.cuda.is_available(), "CUDA unavailable"; print("GPU:", torch.cuda.get_device_name()); print("torch:", torch.__version__, "transformers:", transformers.__version__)'
"$AVANT_GARDE_PYTHON" -m avant_garde.cli smoke-vit --device cuda \
    --output "$RUN_DIR/vit-smoke.json" "${offline[@]}"
"$AVANT_GARDE_PYTHON" -m avant_garde.cli gpt2 --device cuda \
    --context 128 --windows 32 --output "$RUN_DIR/gpt2-smoke.json" "${offline[@]}"
"$AVANT_GARDE_PYTHON" -m avant_garde.summarize "$RUN_DIR/gpt2-smoke.json" \
    --csv "$RUN_DIR/comparison.csv" --plot "$RUN_DIR/comparison.png"
printf 'Results: %s\n' "$RUN_DIR"

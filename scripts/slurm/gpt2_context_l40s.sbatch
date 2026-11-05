#!/bin/bash
#SBATCH --account=cs471
#SBATCH --job-name=avant-garde-context
#SBATCH --partition=l40s
#SBATCH --gres=gpu:nvidia_l40s:1
#SBATCH --cpus-per-task=6
#SBATCH --mem=32G
#SBATCH --time=04:00:00
#SBATCH --output=slurm-%x-%j.out

set -euo pipefail
cd "${SLURM_SUBMIT_DIR:?Submit from the repository root}"
source scripts/slurm/environment.sh
RUN_DIR="$AVANT_GARDE_DATA_ROOT/runs/context-${SLURM_JOB_ID}"
mkdir -p "$RUN_DIR/gpt2"
finish() {
    local status=$?
    trap - EXIT
    shopt -s nullglob
    local reports=("$RUN_DIR"/gpt2/*.json)
    if [[ -n "${AVANT_GARDE_VIT_RESULTS:-}" ]]; then
        reports+=("$AVANT_GARDE_VIT_RESULTS"/*.json)
    fi
    if (( ${#reports[@]} )); then
        if ! "$AVANT_GARDE_PYTHON" -m avant_garde.summarize "${reports[@]}" \
            --csv "$RUN_DIR/comparison.csv" --plot "$RUN_DIR/comparison.png"; then
            if (( status == 0 )); then status=1; fi
        fi
    fi
    printf 'Results: %s\n' "$RUN_DIR"
    exit "$status"
}
trap finish EXIT
"$AVANT_GARDE_PYTHON" -c 'import torch, matplotlib; assert torch.cuda.is_available(), "CUDA unavailable"; print(torch.cuda.get_device_name())'
"$AVANT_GARDE_PYTHON" -m avant_garde.cli sweep --config configs/gpt2_context.json \
    --device cuda --output-dir "$RUN_DIR/gpt2" --extra "${offline[@]}"

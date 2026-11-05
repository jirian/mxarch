#!/bin/bash
#SBATCH --account=cs471
#SBATCH --job-name=avant-garde-size
#SBATCH --partition=l40s
#SBATCH --gres=gpu:nvidia_l40s:1
#SBATCH --cpus-per-task=6
#SBATCH --mem=32G
#SBATCH --time=04:00:00
#SBATCH --output=slurm-%x-%j.out

set -euo pipefail
cd "${SLURM_SUBMIT_DIR:?Submit from the repository root}"
source scripts/slurm/environment.sh
families="${AVANT_GARDE_FAMILIES:-both}"
case "$families" in
    both|gpt2|vit) ;;
    *) printf 'AVANT_GARDE_FAMILIES must be both, gpt2, or vit\n' >&2; exit 2 ;;
esac
RUN_DIR="$AVANT_GARDE_DATA_ROOT/runs/size-${SLURM_JOB_ID}"
mkdir -p "$RUN_DIR"
summarize_reports() {
    shopt -s nullglob
    local reports=("$RUN_DIR"/gpt2/*.json "$RUN_DIR"/vit/*.json)
    if [[ -n "${AVANT_GARDE_GPT2_RESULTS:-}" ]]; then
        reports+=("$AVANT_GARDE_GPT2_RESULTS"/*.json)
    fi
    if (( ${#reports[@]} )); then
        "$AVANT_GARDE_PYTHON" -m avant_garde.summarize "${reports[@]}" \
            --csv "$RUN_DIR/comparison.csv" --plot "$RUN_DIR/comparison.png" || return $?
    fi
    printf 'Results: %s\n' "$RUN_DIR"
}
finish() {
    local status=$?
    trap - EXIT
    if ! summarize_reports; then
        if (( status == 0 )); then status=1; fi
    fi
    exit "$status"
}
# Preserve graphs of completed models if a later download/model fails.
trap finish EXIT
"$AVANT_GARDE_PYTHON" -c 'import torch, transformers, datasets, PIL, numpy, matplotlib; assert torch.cuda.is_available(), "CUDA unavailable"; print("GPU:", torch.cuda.get_device_name()); print("torch:", torch.__version__, "transformers:", transformers.__version__)'
if [[ "$families" != vit ]]; then
    "$AVANT_GARDE_PYTHON" -m avant_garde.cli sweep \
        --config configs/gpt2_size.json --device cuda --output-dir "$RUN_DIR/gpt2" \
        --extra "${offline[@]}"
fi
if [[ "$families" != gpt2 ]]; then
    if [[ -z "${AVANT_GARDE_IMAGENET_MANIFEST:-}" ]]; then
        subset="$AVANT_GARDE_DATA_ROOT/imagenet-validation-1000-seed0"
        "$AVANT_GARDE_PYTHON" -m avant_garde.imagenet --output-dir "$subset" \
            --samples 1000 --seed 0 \
            --revision "${AVANT_GARDE_IMAGENET_REVISION:-49e2ee26f3810fb5a7536bbf732a7b07389a47b5}" \
            "${offline[@]}"
        export AVANT_GARDE_IMAGENET_MANIFEST="$subset/validation.csv"
    fi
    test -r "$AVANT_GARDE_IMAGENET_MANIFEST"
    "$AVANT_GARDE_PYTHON" -m avant_garde.cli sweep \
        --config configs/vit_size.json --device cuda --output-dir "$RUN_DIR/vit" \
        --extra --manifest "$AVANT_GARDE_IMAGENET_MANIFEST" "${offline[@]}"
fi

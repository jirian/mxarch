#!/bin/bash
#SBATCH --account=cs471
#SBATCH --job-name=avant-garde-hierarchical
#SBATCH --partition=l40s
#SBATCH --gres=gpu:nvidia_l40s:1
#SBATCH --cpus-per-task=6
#SBATCH --mem=32G
#SBATCH --time=04:00:00
#SBATCH --array=0-13%1
#SBATCH --output=slurm-%x-%A_%a.out

set -euo pipefail
cd "${SLURM_SUBMIT_DIR:?Submit from the repository root}"
source scripts/slurm/environment.sh
RUN_DIR="$AVANT_GARDE_DATA_ROOT/runs/hierarchical-${SLURM_ARRAY_JOB_ID:?}"
task="${SLURM_ARRAY_TASK_ID:?}"
[[ "$task" =~ ^[0-9]+$ ]] && (( task < 14 )) || exit 2
mkdir -p "$RUN_DIR/gpt2" "$RUN_DIR/vit" "$RUN_DIR/plots"
common=(--device cuda --backend figure8 --rounding even --flatten-rounding trunc
        --activation-policy hierarchical --exponent-overflow wide --bootstrap-replicates 1000)
if (( task < 12 )); then
    models=(gpt2 gpt2-medium gpt2-large gpt2-xl)
    contexts=(128 512 1024)
    model="${models[task / 3]}"
    context="${contexts[task % 3]}"
    report="$RUN_DIR/gpt2/${model}-ctx${context}.json"
    "$AVANT_GARDE_PYTHON" -m avant_garde.cli gpt2 --model "openai-community/$model" \
        --context "$context" --windows "$((32768 / context))" \
        "${common[@]}" --output "$report" "${offline[@]}"
else
    models=(vit-base-patch16-224 vit-large-patch16-224)
    model="${models[task - 12]}"
    manifest="${AVANT_GARDE_IMAGENET_MANIFEST:-$AVANT_GARDE_DATA_ROOT/imagenet-validation-1000-seed0/validation.csv}"
    test -r "$manifest"
    report="$RUN_DIR/vit/${model}.json"
    "$AVANT_GARDE_PYTHON" -m avant_garde.cli vit --model "google/$model" \
        --manifest "$manifest" --samples 1000 --batch-size 8 \
        "${common[@]}" --output "$report" "${offline[@]}"
fi
"$AVANT_GARDE_PYTHON" -m avant_garde.summarize "$report" \
    --csv "$RUN_DIR/plots/task-${task}.csv" --plot "$RUN_DIR/plots/task-${task}.png"
printf 'Results: %s\n' "$RUN_DIR"

#!/bin/bash
#SBATCH --account=cs471
#SBATCH --job-name=avant-garde-xcheck-size
#SBATCH --partition=l40s
#SBATCH --gres=gpu:nvidia_l40s:1
#SBATCH --cpus-per-task=6
#SBATCH --mem=32G
#SBATCH --time=02:00:00
#SBATCH --output=/work/cs-471/mixedprecisionarchitects/avant-garde/runs/slurm-%x-%j.out

# Flattening penalty versus GPT-2 size (Medium, Large, XL). Same protocol
# as calib-4859947: English Wikipedia text, context 1024, 64 windows, nearest.
set -euo pipefail
BASE=/work/cs-471/mixedprecisionarchitects/avant-garde
export AVANT_GARDE_PYTHON="$BASE/venv/bin/python"
export AVANT_GARDE_DATA_ROOT="$BASE/data"
export AVANT_GARDE_TMP_ROOT="$BASE/tmp"
export AVANT_GARDE_OFFLINE=1
cd "${SLURM_SUBMIT_DIR:?Submit using sbatch from the repository root}"
source scripts/slurm/environment.sh
RUN_DIR="$BASE/runs/xsize-${SLURM_JOB_ID}"
mkdir -p "$RUN_DIR"
TEXT="$BASE/data/text/wikipedia-20231101-en-150.txt"
git rev-parse HEAD > "$RUN_DIR/git-commit.txt"; git status --short >> "$RUN_DIR/git-commit.txt"

# microxcaling bf0 cross-check done in job 4860058 (27.709 vs ours 27.734);
# its bfloat16 vector-op recipe gives nonfinite GPT-2 loss and is skipped.

for model in gpt2-medium gpt2-large gpt2-xl; do
    "$AVANT_GARDE_PYTHON" -m avant_garde.cli gpt2 --device cuda --offline --text-file "$TEXT" \
        --model "openai-community/$model" --context 1024 --windows 64 --rounding nearest \
        --modes fp32 mx9_hierarchical mx9_flattened mxint8_b16 \
        --output "$RUN_DIR/${model}-ctx1024-all-nearest.json"
    "$AVANT_GARDE_PYTHON" -m avant_garde.cli gpt2 --device cuda --offline --text-file "$TEXT" \
        --model "openai-community/$model" --context 1024 --windows 64 --rounding nearest \
        --weights-only --modes fp32 mx9_hierarchical mx9_flattened \
        --output "$RUN_DIR/${model}-ctx1024-weights-nearest.json"
done
"$AVANT_GARDE_PYTHON" -m avant_garde.summarize "$RUN_DIR"/gpt2-*.json \
    --csv "$RUN_DIR/comparison.csv" --plot "$RUN_DIR/comparison.png"
printf 'Results: %s\n' "$RUN_DIR"

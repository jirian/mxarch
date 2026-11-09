#!/bin/bash
#SBATCH --account=cs471
#SBATCH --job-name=avant-garde-fallback
#SBATCH --partition=l40s
#SBATCH --gres=gpu:nvidia_l40s:1
#SBATCH --cpus-per-task=6
#SBATCH --mem=32G
#SBATCH --time=01:00:00
#SBATCH --output=/work/cs-471/mixedprecisionarchitects/avant-garde/runs/slurm-%x-%j.out

# H1.1 layer fallback: flatten everything except the named modules, which keep
# hierarchical MX9 (or FP32). The tied LM head dominates flattening error in
# GPT-2 Small/Medium. Baselines: calib-4859947 and xsize-4860082 (same windows).
set -euo pipefail
BASE=/work/cs-471/mixedprecisionarchitects/avant-garde
export AVANT_GARDE_PYTHON="$BASE/venv/bin/python"
export AVANT_GARDE_DATA_ROOT="$BASE/data"
export AVANT_GARDE_TMP_ROOT="$BASE/tmp"
export AVANT_GARDE_OFFLINE=1
cd "${SLURM_SUBMIT_DIR:?Submit using sbatch from the repository root}"
source scripts/slurm/environment.sh
RUN_DIR="$BASE/runs/fallback-${SLURM_JOB_ID}"
mkdir -p "$RUN_DIR"
TEXT="$BASE/data/text/wikipedia-20231101-en-150.txt"
git rev-parse HEAD > "$RUN_DIR/git-commit.txt"; git status --short >> "$RUN_DIR/git-commit.txt"
run() { "$AVANT_GARDE_PYTHON" -m avant_garde.cli gpt2 --device cuda --offline --text-file "$TEXT" \
            --context 1024 --windows 64 --rounding nearest --modes fp32 mx9_hierarchical mx9_flattened "$@"; }

for model in gpt2 gpt2-medium; do
    M="openai-community/$model"
    run --model "$M" --exempt '^lm_head$' --output "$RUN_DIR/$model-all-head-hier.json"
    run --model "$M" --exempt '^lm_head$' --exempt-mode fp32 --output "$RUN_DIR/$model-all-head-fp32.json"
    run --model "$M" --exempt 'mlp\.c_proj$' --output "$RUN_DIR/$model-all-cproj-hier.json"
    run --model "$M" --exempt '^lm_head$|mlp\.c_proj$' --output "$RUN_DIR/$model-all-head-cproj-hier.json"
    run --model "$M" --weights-only --exempt '^lm_head$' --output "$RUN_DIR/$model-weights-head-hier.json"
done
printf 'Results: %s\n' "$RUN_DIR"

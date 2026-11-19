#!/bin/bash
#SBATCH --account=cs471
#SBATCH --job-name=avant-garde-acc-gpt2
#SBATCH --partition=l40s
#SBATCH --gres=gpu:nvidia_l40s:1
#SBATCH --cpus-per-task=6
#SBATCH --mem=32G
#SBATCH --time=03:00:00
#SBATCH --output=/work/cs-471/mixedprecisionarchitects/avant-garde/runs/slurm-%x-%j.out

# Accumulator sensitivity on GPT-2 Small/Medium (where flattening fails):
# Figure 8 backend, accumulator {fp32, bf16, fp16, fp32-m14} x flattening
# rounding {nearest, trunc}, status-report text, context 1024, 32 windows,
# FP32 activations. Each run pairs flattened with hierarchical MX9.
set -euo pipefail
BASE=/work/cs-471/mixedprecisionarchitects/avant-garde
export AVANT_GARDE_PYTHON="$BASE/venv-qwen/bin/python"
export AVANT_GARDE_DATA_ROOT="$BASE/data" AVANT_GARDE_TMP_ROOT="$BASE/tmp" AVANT_GARDE_OFFLINE=1
cd "${SLURM_SUBMIT_DIR:?Submit using sbatch from repo-merge}"
source scripts/slurm/environment.sh
RUN_DIR="$BASE/runs/acc-gpt2-${SLURM_JOB_ID}"
mkdir -p "$RUN_DIR"
cp MERGE_COMMIT "$RUN_DIR/git-commit.txt"
TEXT="$BASE/data/text/wikipedia-20231101-en-150.txt"
for model in gpt2 gpt2-medium; do
    for acc in fp32 bf16 fp16 fp32-m14; do
        for rnd in nearest trunc; do
            "$AVANT_GARDE_PYTHON" -m avant_garde.cli gpt2 --device cuda --offline --text-file "$TEXT" \
                --model "openai-community/$model" --context 1024 --windows 32 --rounding nearest \
                --backend figure8 --activation-policy fp32 --accumulator "$acc" --flatten-rounding "$rnd" \
                --modes mx9_hierarchical mx9_flattened --output "$RUN_DIR/$model-acc-$acc-flat-$rnd.json"
        done
    done
done
printf 'Results: %s\n' "$RUN_DIR"

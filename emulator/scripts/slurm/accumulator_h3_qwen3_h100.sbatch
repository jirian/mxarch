#!/bin/bash
#SBATCH --account=cs471
#SBATCH --job-name=avant-garde-acc-h3-qwen3
#SBATCH --partition=h100
#SBATCH --gres=gpu:nvidia_h100:1
#SBATCH --cpus-per-task=12
#SBATCH --mem=64G
#SBATCH --time=03:00:00
#SBATCH --output=/work/cs-471/mixedprecisionarchitects/avant-garde/runs/slurm-%x-%j.out

# 1. H3: time one Qwen3-8B prefill layer at 8k and 32k (BF16, native kernels)
#    and evaluate the speedup bound S = 1/(f + (1-f)/s).
# 2. Accumulator sensitivity on Qwen3-8B: Figure 8 backend, accumulator
#    {fp32, bf16, fp16, fp32-m14}, truncating flattening, context 2048,
#    8 windows (Figure 8 runs ~1 min per window and mode).
set -euo pipefail
BASE=/work/cs-471/mixedprecisionarchitects/avant-garde
export AVANT_GARDE_PYTHON="$BASE/venv-qwen/bin/python"
export AVANT_GARDE_DATA_ROOT="$BASE/data" AVANT_GARDE_TMP_ROOT="$BASE/tmp" AVANT_GARDE_OFFLINE=1
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
cd "${SLURM_SUBMIT_DIR:?Submit using sbatch from repo-merge}"
source scripts/slurm/environment.sh
RUN_DIR="$BASE/runs/acc-h3-qwen3-${SLURM_JOB_ID}"
mkdir -p "$RUN_DIR"
cp MERGE_COMMIT "$RUN_DIR/git-commit.txt"
"$AVANT_GARDE_PYTHON" scripts/h3_layer_profile.py --model Qwen/Qwen3-8B --output "$RUN_DIR/h3-layer-profile.json" \
    || echo "H3 profile failed; continuing with the accumulator runs" >&2
TEXT="$BASE/data/text/wikipedia-20231101-en-150.txt"
for acc in fp32 bf16 fp16 fp32-m14; do
    "$AVANT_GARDE_PYTHON" -m avant_garde.cli gpt2 --device cuda --offline --text-file "$TEXT" \
        --model Qwen/Qwen3-8B --context 2048 --windows 8 --rounding nearest \
        --backend figure8 --activation-policy fp32 --accumulator "$acc" --flatten-rounding trunc \
        --modes mx9_hierarchical mx9_flattened --output "$RUN_DIR/qwen3-8b-acc-$acc-flat-trunc.json"
done
printf 'Results: %s\n' "$RUN_DIR"

#!/bin/bash
#SBATCH --account=cs471
#SBATCH --job-name=avant-garde-calib
#SBATCH --partition=l40s
#SBATCH --gres=gpu:nvidia_l40s:1
#SBATCH --cpus-per-task=6
#SBATCH --mem=32G
#SBATCH --time=02:00:00
#SBATCH --output=/work/cs-471/mixedprecisionarchitects/avant-garde/runs/slurm-%x-%j.out

# Flattening calibration against Avant-Garde Table 4 (GPT-2 Small, English Wikipedia).
# Same 65,536 tokens at context 1024 and 128 isolate the context-length effect.
# Rounding "nearest" (ties away from zero) is microxcaling's default; "trunc" is a
# hardware right-shift. Submit from the repository root with --account=cs471.
set -euo pipefail
BASE=/work/cs-471/mixedprecisionarchitects/avant-garde
export AVANT_GARDE_PYTHON="$BASE/venv/bin/python"
export AVANT_GARDE_DATA_ROOT="$BASE/data"
export AVANT_GARDE_TMP_ROOT="$BASE/tmp"
export AVANT_GARDE_OFFLINE=1
cd "${SLURM_SUBMIT_DIR:?Submit using sbatch from the repository root}"
source scripts/slurm/environment.sh
RUN_DIR="$BASE/runs/calib-${SLURM_JOB_ID}"
mkdir -p "$RUN_DIR"
TEXT="$BASE/data/text/wikipedia-20231101-en-150.txt"
cp "${TEXT%.txt}.source.json" "$RUN_DIR/text.source.json"
git rev-parse HEAD > "$RUN_DIR/git-commit.txt"; git status --short >> "$RUN_DIR/git-commit.txt"

"$AVANT_GARDE_PYTHON" -c 'import torch; assert torch.cuda.is_available(); print("GPU:", torch.cuda.get_device_name())'
run() { "$AVANT_GARDE_PYTHON" -m avant_garde.cli gpt2 --device cuda --text-file "$TEXT" "${offline[@]}" "$@"; }

# 0. Fail fast on paths, offline loading and the new modes.
run --context 128 --windows 2 --rounding nearest --bootstrap-replicates 10 \
    --modes fp32 mx9_flattened mxint8 --output "$RUN_DIR/check.json"
# 1. Main comparison, all GEMM operands quantized.
run --context 1024 --windows 64 --rounding nearest \
    --modes fp32 mx9_hierarchical mx9_flattened mx9_lossless mxint8 mxint8_b16 \
    --output "$RUN_DIR/ctx1024-all-nearest.json"
# 2. Hardware-shift rounding.
run --context 1024 --windows 64 --rounding trunc \
    --modes fp32 mx9_hierarchical mx9_flattened mxint8_b16 \
    --output "$RUN_DIR/ctx1024-all-trunc.json"
# 3. Weights only.
run --context 1024 --windows 64 --rounding nearest --weights-only \
    --modes fp32 mx9_hierarchical mx9_flattened mxint8 \
    --output "$RUN_DIR/ctx1024-weights-nearest.json"
# 4. Short context, same tokens (compares with the earlier smoke run).
run --context 128 --windows 512 --rounding nearest \
    --modes fp32 mx9_hierarchical mx9_flattened mx9_lossless mxint8 mxint8_b16 \
    --output "$RUN_DIR/ctx128-all-nearest.json"

"$AVANT_GARDE_PYTHON" -m avant_garde.summarize "$RUN_DIR"/ctx*.json \
    --csv "$RUN_DIR/comparison.csv" --plot "$RUN_DIR/comparison.png"
printf 'Results: %s\n' "$RUN_DIR"

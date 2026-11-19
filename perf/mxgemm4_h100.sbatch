#!/bin/bash
#SBATCH --account=cs471
#SBATCH --job-name=ag-mxgemm-k16
#SBATCH --partition=h100
#SBATCH --gres=gpu:nvidia_h100:1
#SBATCH --cpus-per-task=6
#SBATCH --mem=32G
#SBATCH --time=01:00:00
#SBATCH --output=/work/cs-471/mixedprecisionarchitects/avant-garde/runs/slurm-%x-%j.out

# N1: is our 2x larger MX9 overhead (vs the paper) explained by the INT8 baseline?
# mxgemm4 adds INT8K16: plain INT8 issued as m16n8k16 MMAs, as in NVIDIA's
# immaTensorCoreGemm sample (IMMA.16816 only). All four variants are verified
# exactly against a host reference first, then timed on the Qwen3-8B linear
# layers from decode (M=16) to prefill (M=4096).
set -uo pipefail
BASE=/work/cs-471/mixedprecisionarchitects/avant-garde
DIR=$BASE/perf/mxgemm
OUT=$BASE/runs/mxgemm-k16-${SLURM_JOB_ID}
mkdir -p "$OUT"
cp "$DIR/mxgemm4.cu" "$OUT/"
nvidia-smi --query-gpu=name,driver_version,clocks.max.sm,clocks.max.mem,power.limit --format=csv | tee "$OUT/gpu.csv"
"$DIR/mxgemm4" | tee "$OUT/timing.txt"
echo "exit ${PIPESTATUS[0]}"
printf 'Results: %s\n' "$OUT"

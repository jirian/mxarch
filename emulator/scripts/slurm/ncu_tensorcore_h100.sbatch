#!/bin/bash
#SBATCH --account=cs471
#SBATCH --job-name=ag-ncu-tc
#SBATCH --partition=h100
#SBATCH --gres=gpu:nvidia_h100:1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=00:30:00
#SBATCH --output=/work/cs-471/mixedprecisionarchitects/avant-garde/runs/slurm-%x-%j.out

# Performance-track feasibility: can we read per-opcode SASS instruction counts
# for the CUDA tensor-core GEMM samples (FP16 WMMA and INT8 IMMA) on an H100?
set -uo pipefail
BASE=/work/cs-471/mixedprecisionarchitects/avant-garde
CUDA=/ssoft/spack/pinot-noir/kuma-h100/v2/spack/opt/spack/linux-rhel9-zen4/nvhpc-24.7/cuda-12.5.1-ulebdd3d2frpxeygqmhuv4kovkoywbq3
export PATH="$CUDA/bin:$PATH"
OUT="$BASE/runs/ncu-${SLURM_JOB_ID}"
mkdir -p "$OUT"
nvidia-smi --query-gpu=name,driver_version,clocks.max.sm --format=csv | tee "$OUT/gpu.csv"
for app in cudaTensorCoreGemm immaTensorCoreGemm; do
    BIN="$BASE/perf/bin/$app"
    "$BIN" | tee "$OUT/$app.stdout"
    ncu --target-processes all -k regex:compute_gemm -c 1 \
        --section InstructionStats --section SpeedOfLight --section ComputeWorkloadAnalysis \
        --metrics sass__inst_executed_per_opcode,smsp__inst_executed.sum,sm__cycles_elapsed.avg \
        --csv --page raw "$BIN" > "$OUT/$app.ncu.csv" 2> "$OUT/$app.ncu.err"
    echo "$app ncu raw exit $?"; tail -3 "$OUT/$app.ncu.err"
    ncu -k regex:compute_gemm -c 1 --section InstructionStats --page details \
        --print-details all "$BIN" > "$OUT/$app.ncu-details.txt" 2>&1
    echo "$app ncu details exit $?"
done
printf 'Results: %s\n' "$OUT"

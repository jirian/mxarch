#!/usr/bin/env bash
#SBATCH --job-name=ag-orfs-sweep-sm
#SBATCH --account=cs471
#SBATCH --partition=mig12gb
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=2
#SBATCH --mem=11G
#SBATCH --time=02:00:00
#SBATCH --output=slurm-ag-orfs-sweep-sm-%j.out
# Place-and-route sweep: 6 sign-magnitude wrappers x 6 clock periods = 36 ORFS runs, 2 at a time (MIG slices allow 2 cores).
# The GPU slice is unused; it is requested only to obtain CPUs on a GPU partition.
set -euo pipefail
cd /work/cs-471/mixedprecisionarchitects/avant-garde/tmp/rtl
DESIGNS="reg_dp_sm7 reg_dp_sm8 reg_dp_lateshift_sm reg_ot_flat8_sm_trunc reg_ot_flat8_sm_nearest reg_ot_wide9_sm"
PERIODS="2.0 2.5 3.0 3.5 4.0 5.0"
for d in $DESIGNS; do for p in $PERIODS; do echo "$d $p"; done; done |
  xargs -P 2 -n 2 apptainer exec orfs.sif work/syn/orfs/run_orfs.sh
echo "sweep complete"

#!/bin/bash
#SBATCH --account=cs471
#SBATCH --job-name=avant-garde-hierarchical-plots
#SBATCH --partition=mig12gb
#SBATCH --gres=gpu:nvidia_h100_1g.12gb:1
#SBATCH --cpus-per-task=2
#SBATCH --mem=10G
#SBATCH --time=00:15:00
#SBATCH --output=slurm-%x-%j.out

set -euo pipefail
# Cluster QOS requires a GPU GRES even though matplotlib executes on the CPU.
cd "${SLURM_SUBMIT_DIR:?Submit from the repository root}"
source scripts/slurm/environment.sh
array_job="${1:?Pass the hierarchical sweep array job ID}"
[[ "$array_job" =~ ^[0-9]+$ ]] || exit 2
RUN_DIR="$AVANT_GARDE_DATA_ROOT/runs/hierarchical-$array_job"
shopt -s nullglob
reports=("$RUN_DIR"/gpt2/*.json "$RUN_DIR"/vit/*.json)
(( ${#reports[@]} )) || { printf 'No completed reports in %s\n' "$RUN_DIR" >&2; exit 1; }
"$AVANT_GARDE_PYTHON" -m avant_garde.summarize "${reports[@]}" \
    --csv "$RUN_DIR/comparison.csv" --plot "$RUN_DIR/comparison.png"
printf 'Summarized %s of 14 experiments in %s\n' "${#reports[@]}" "$RUN_DIR"
# Write partial graphs on failure, but do not mark an incomplete sweep successful.
(( ${#reports[@]} == 14 ))

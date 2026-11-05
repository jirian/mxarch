#!/bin/bash
# Source after cd to the repository root. Slurm directives stay in each sbatch.
: "${AVANT_GARDE_PYTHON:?Set AVANT_GARDE_PYTHON to the environment python executable}"
test -x "$AVANT_GARDE_PYTHON"
test -f avant_garde/cli.py
export PYTHONPATH="$PWD${PYTHONPATH:+:$PYTHONPATH}"
# AVANT_GARDE_SCRATCH remains a legacy override for the persistent data root.
export AVANT_GARDE_DATA_ROOT="${AVANT_GARDE_DATA_ROOT:-${AVANT_GARDE_SCRATCH:-/scratch/$USER/avant-garde-reproduction}}"
# Preserve the login token path before relocating caches. Never copy tokens to
# shared cache or result folders.
if [[ -z "${HF_TOKEN_PATH:-}" ]]; then
    for token_file in "${HF_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/huggingface}/token" \
                      "${XDG_CACHE_HOME:-$HOME/.cache}/huggingface/token"; do
        if [[ -r "$token_file" ]]; then
            export HF_TOKEN_PATH="$token_file"
            break
        fi
    done
fi
export HF_HOME="$AVANT_GARDE_DATA_ROOT/huggingface"
export HF_HUB_CACHE="$HF_HOME/hub"
export HF_DATASETS_CACHE="$AVANT_GARDE_DATA_ROOT/datasets"
export TMPDIR="${AVANT_GARDE_TMP_ROOT:-/scratch/$USER/avant-garde-reproduction/tmp}/${SLURM_JOB_ID:?Run inside a Slurm job}"
export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-6}"
export TOKENIZERS_PARALLELISM=false
mkdir -p "$HF_HOME" "$HF_HUB_CACHE" "$HF_DATASETS_CACHE" "$TMPDIR"
offline=()
if [[ "${AVANT_GARDE_OFFLINE:-0}" == 1 ]]; then
    offline=(--offline)
fi

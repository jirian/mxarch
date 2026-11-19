"""Summarize 2x2 grid runs: flattened vs hierarchical MX9 perplexity change.

For each JSON with both modes, resample text windows with replacement
(paired: the same windows for both modes) and report Delta_PPL in percent
with a 95% percentile interval, as in the status report.
Usage: python grid_summary.py RUN_DIR [RUN_DIR ...]
"""
import glob
import json
import math
import os
import random
import sys

REPLICATES = 2000


def window_arrays(run):
    obs = run["metrics"]["observations"]
    losses = obs["loss_sums"]
    tokens = obs.get("token_counts") or obs.get("tokens")
    if tokens is None:
        per = run["metrics"]["scored_tokens"] / len(losses)
        tokens = [per] * len(losses)
    return losses, tokens


def ppl(losses, tokens, idx):
    return math.exp(sum(losses[i] for i in idx) / sum(tokens[i] for i in idx))


def summarize(path):
    d = json.load(open(path))
    if "runs" not in d:          # e.g. multiple-choice results in the same directory
        return None
    runs = {r["mode"]: r for r in d["runs"]}
    if not {"mx9_hierarchical", "mx9_flattened"} <= runs.keys():
        return None
    h, f = runs["mx9_hierarchical"], runs["mx9_flattened"]
    hl, ht = window_arrays(h)
    fl, ft = window_arrays(f)
    n = len(hl)
    full = list(range(n))
    delta = 100 * (ppl(fl, ft, full) / ppl(hl, ht, full) - 1)
    rng = random.Random(0)
    samples = []
    for _ in range(REPLICATES):
        idx = [rng.randrange(n) for _ in range(n)]
        samples.append(100 * (ppl(fl, ft, idx) / ppl(hl, ht, idx) - 1))
    samples.sort()
    lo, hi = samples[int(0.025 * REPLICATES)], samples[int(0.975 * REPLICATES) - 1]
    cfg = f["config"]
    return (os.path.basename(path).removesuffix(".json"), f["activation_policy"],
            cfg.get("flatten_rounding"), f["numerical_backend"], n,
            h["metrics"]["perplexity"], f["metrics"]["perplexity"], delta, lo, hi)


print("run\tactivations\tflatten_rounding\tbackend\twindows\tppl_hier\tppl_flat\tdelta_pct\tci_lo\tci_hi")
for run_dir in sys.argv[1:]:
    for path in sorted(glob.glob(os.path.join(run_dir, "*.json"))):
        row = summarize(path)
        if row:
            print("\t".join(f"{v:.3f}" if isinstance(v, float) else str(v) for v in row))

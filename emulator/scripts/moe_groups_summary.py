"""Summarize the MoE rounding job: full flattening and the H1.1 group breakdown.

For each rounding mode, every `only-<group>-flat-<rnd>.json` run flattens one
layer group and keeps the rest as hierarchical MX9; the hierarchical
reference comes from `all-flat-<rnd>.json`. Reports each group's Delta_PPL and
share of the full-flattening loss with paired bootstrap CIs, then ranks the
groups on the even-indexed windows and validates the ranking on the odd ones
(the split promised in the status report). Assumes the first windows are the
same in every run (fixed text, fixed window selection).
Usage: python moe_groups_summary.py RUN_DIR
"""
import glob
import json
import math
import os
import random
import re
import sys

REPLICATES = 2000
run_dir = sys.argv[1]


def windows(path, mode):
    run = next(r for r in json.load(open(path))["runs"] if r["mode"] == mode)
    obs = run["metrics"]["observations"]
    return obs["loss_sums"], obs["token_counts"]


def delta(flat, ref, idx):
    ppl = lambda lt: math.exp(sum(lt[0][i] for i in idx) / sum(lt[1][i] for i in idx))
    return 100 * (ppl(flat) / ppl(ref) - 1)


def ci(flat, ref, idx):
    rng = random.Random(0)
    vals = sorted(delta(flat, ref, [rng.choice(idx) for _ in idx]) for _ in range(REPLICATES))
    return vals[int(.025 * REPLICATES)], vals[int(.975 * REPLICATES) - 1]


for rnd in ("nearest", "trunc"):
    full_path = os.path.join(run_dir, f"all-flat-{rnd}.json")
    if not os.path.exists(full_path):
        print(f"[{rnd}] missing {full_path}")
        continue
    ref = windows(full_path, "mx9_hierarchical")
    full = windows(full_path, "mx9_flattened")
    n = len(ref[0])
    idx = list(range(n))
    d_full = delta(full, ref, idx)
    lo, hi = ci(full, ref, idx)
    print(f"\n[{rnd}] all GEMMs flattened: {d_full:+.2f}% [{lo:+.2f}, {hi:+.2f}] over {n} windows")
    groups = {}
    for path in sorted(glob.glob(os.path.join(run_dir, f"only-*-flat-{rnd}.json"))):
        name = re.match(r"only-(.+)-flat-", os.path.basename(path)).group(1)
        # The group run's only mode is mx9_hierarchical with the group exempted to flattened.
        groups[name] = windows(path, "mx9_hierarchical")
    print(f"{'group':16s} {'delta %':>8s} {'95% CI':>18s} {'share of full':>14s}")
    for name, flat in sorted(groups.items(), key=lambda kv: -delta(kv[1], ref, idx)):
        d = delta(flat, ref, idx)
        lo, hi = ci(flat, ref, idx)
        print(f"{name:16s} {d:+8.2f} [{lo:+6.2f}, {hi:+6.2f}] {d / d_full if d_full else float('nan'):14.0%}")
    total = sum(delta(f, ref, idx) for f in groups.values())
    print(f"sum of groups: {total:+.2f}% vs full {d_full:+.2f}% (additivity check)")
    even, odd = idx[0::2], idx[1::2]
    ranked = sorted(groups, key=lambda g: -delta(groups[g], ref, even))
    print("rank on even windows:", ", ".join(f"{g} {delta(groups[g], ref, even):+.2f}" for g in ranked))
    print("validate on odd:     ", ", ".join(f"{g} {delta(groups[g], ref, odd):+.2f}" for g in ranked))

import json, sys, math, random
d = sys.argv[1]
def obs(f, mode):
    r = json.load(open(f"{d}/{f}")); x = {y["mode"]: y for y in r["runs"]}[mode]
    o = x["metrics"]["observations"]
    return o["loss_sums"], o["token_counts"]
def paired(a, b, reps=2000, seed=0):
    (la, n), (lb, _) = a, b
    rng = random.Random(seed); k = len(la)
    ratio = lambda idx: math.exp((sum(la[i] for i in idx) - sum(lb[i] for i in idx)) / sum(n[i] for i in idx))
    point = ratio(range(k)); boots = sorted(ratio([rng.randrange(k) for _ in range(k)]) for _ in range(reps))
    return point, boots[int(.025 * reps)], boots[int(.975 * reps)]
hier = obs("ctx2048-all.json", "mx9_hierarchical"); fp = obs("ctx2048-all.json", "fp32")
for label, f, m, base, bl in [("flattened vs MX9 (all)", "ctx2048-all.json", "mx9_flattened", hier, "MX9"),
                              ("flattened, lm_head MX9 vs MX9 (all)", "ctx2048-all-head-hier.json", "mx9_flattened", hier, "MX9"),
                              ("MX9 vs FP32 (all)", "ctx2048-all.json", "mx9_hierarchical", fp, "FP32"),
                              ("flattened vs MX9 (weights)", "ctx2048-weights.json", "mx9_flattened", obs("ctx2048-weights.json", "mx9_hierarchical"), "MX9w")]:
    p, lo, hi = paired(obs(f, m), base)
    print(f"{label:38s} {100*(p-1):+6.3f}%  95% CI [{100*(lo-1):+6.3f}%, {100*(hi-1):+6.3f}%]")

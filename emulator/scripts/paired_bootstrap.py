"""Paired window-bootstrap ratios between runs scored on identical windows.

Usage: paired_bootstrap.py RUN_DIR ALL.json HEAD.json [...]  (pairs of files)
ALL.json holds fp32 / mx9_hierarchical / mx9_flattened; HEAD.json holds the
flattened run with the LM head kept non-flattened. Input hashes must match.
"""
import json, math, random, sys


def load(path):
    r = json.load(open(path))
    return r["dataset"]["scored_input_sha256"], {x["mode"]: x["metrics"] for x in r["runs"]}


def paired(a, b, reps=2000, seed=0):
    la, n, lb = a["observations"]["loss_sums"], a["observations"]["token_counts"], b["observations"]["loss_sums"]
    ratio = lambda idx: math.exp((sum(la[i] for i in idx) - sum(lb[i] for i in idx)) / sum(n[i] for i in idx))
    rng, k = random.Random(seed), len(la)
    boots = sorted(ratio([rng.randrange(k) for _ in range(k)]) for _ in range(reps))
    return ratio(range(k)), boots[int(.025 * reps)], boots[int(.975 * reps)]


def main():
    d = sys.argv[1]
    for all_f, head_f in zip(sys.argv[2::2], sys.argv[3::2]):
        h0, R = load(f"{d}/{all_f}")
        h1, H = load(f"{d}/{head_f}")
        assert h0 == h1, "different windows"
        print(f"{all_f}: {R['fp32']['scored_tokens']} tokens, FP32 ppl {R['fp32']['perplexity']:.4f}")
        for label, a, b in [("MX9 vs FP32", R["mx9_hierarchical"], R["fp32"]),
                            ("flattened vs MX9", R["mx9_flattened"], R["mx9_hierarchical"]),
                            ("flattened, lm_head MX9 vs MX9", H["mx9_flattened"], R["mx9_hierarchical"])]:
            p, lo, hi = paired(a, b)
            print(f"  {label:32s} {100*(p-1):+6.3f}%  95% CI [{100*(lo-1):+6.3f}%, {100*(hi-1):+6.3f}%]")


if __name__ == "__main__":
    main()

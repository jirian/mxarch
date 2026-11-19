"""Multiple-choice accuracy under MX9 emulation (ARC-Challenge, HellaSwag).

Each choice is scored by the summed log-likelihood of its tokens after the
context (acc) and by that sum divided by the choice's character length
(acc_norm), as in lm-evaluation-harness. Each choice runs as its own unpadded
sequence: MX9 blocks along the sequence axis (e.g. of V) would otherwise let
pad tokens share a block scale with real tokens.

Configurations are given as name=mode:flatten_rounding, e.g.
  fp32=fp32:trunc hier=mx9_hierarchical:trunc flat-nearest=mx9_flattened:nearest
Per-question correctness is saved, and every configuration is compared with
the first MX9 hierarchical one by a paired bootstrap over questions.
"""
import argparse
import json
import random
import time

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

from avant_garde.inference import MX9Inference, configure_fp32
from avant_garde.mx9 import MX9Config


def load(path, limit):
    items = [json.loads(line) for line in open(path)]
    return items[:limit] if limit else items


def score(model, tok, item, device):
    ctx = tok(item["context"], add_special_tokens=False)["input_ids"]
    sums = []
    for choice in item["choices"]:
        full = tok(item["context"] + choice, add_special_tokens=False)["input_ids"]
        # Tokenize jointly; the choice is everything after the context prefix.
        start = len(ctx) if full[:len(ctx)] == ctx else len(ctx) - 1
        ids = torch.tensor([full], device=device)
        with torch.inference_mode():
            logp = torch.log_softmax(model(input_ids=ids, use_cache=False).logits[0].float(), -1)
        targets = ids[0, start:]
        sums.append(logp[start - 1:-1].gather(-1, targets[:, None]).sum().item())
    norm = [s / len(c) for s, c in zip(sums, item["choices"])]
    pick = lambda v: max(range(len(v)), key=v.__getitem__)
    return int(pick(sums) == item["label"]), int(pick(norm) == item["label"])


def bootstrap(a, b, reps=2000, seed=0):
    n, rng = len(a), random.Random(seed)
    diffs = []
    for _ in range(reps):
        idx = [rng.randrange(n) for _ in range(n)]
        diffs.append(100 * sum(a[i] - b[i] for i in idx) / n)
    diffs.sort()
    return 100 * sum(x - y for x, y in zip(a, b)) / n, diffs[int(.025 * reps)], diffs[int(.975 * reps) - 1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="Qwen/Qwen3-8B")
    ap.add_argument("--task", action="append", required=True, help="name=path.jsonl")
    ap.add_argument("--config", nargs="+", required=True)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--rounding", default="nearest")
    ap.add_argument("--activation-policy", default="fp32")
    ap.add_argument("--backend", default="dequantized")
    ap.add_argument("--device", default="cuda")
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    configure_fp32()
    tok = AutoTokenizer.from_pretrained(args.model, local_files_only=True)
    model = AutoModelForCausalLM.from_pretrained(args.model, local_files_only=True,
                                                 attn_implementation="eager",
                                                 torch_dtype=torch.float32).eval().to(args.device)
    tasks = {t.split("=", 1)[0]: load(t.split("=", 1)[1], args.limit) for t in args.task}
    results = {"model": args.model, "rounding": args.rounding,
               "activation_policy": args.activation_policy, "backend": args.backend,
               "tasks": {t: len(v) for t, v in tasks.items()}, "configs": {}}
    for spec in args.config:
        name, rest = spec.split("=", 1)
        mode, flat = rest.split(":")
        adapter = MX9Inference(model, mode, MX9Config(args.rounding, flatten_rounding=flat),
                               backend=args.backend, activation_policy=args.activation_policy)
        t0 = time.time()
        per = {}
        with adapter.apply():
            for task, items in tasks.items():
                per[task] = [score(model, tok, it, args.device) for it in items]
        results["configs"][name] = {
            "mode": mode, "flatten_rounding": flat, "seconds": time.time() - t0,
            "accuracy": {t: {"acc": 100 * sum(r[0] for r in v) / len(v),
                             "acc_norm": 100 * sum(r[1] for r in v) / len(v)} for t, v in per.items()},
            "correct": per}
        print(name, json.dumps(results["configs"][name]["accuracy"]), flush=True)
        del adapter
    ref = next(n for n, c in results["configs"].items() if c["mode"] == "mx9_hierarchical")
    results["vs_" + ref] = {}
    for name, c in results["configs"].items():
        for task in tasks:
            for k, key in ((0, "acc"), (1, "acc_norm")):
                a = [r[k] for r in c["correct"][task]]
                b = [r[k] for r in results["configs"][ref]["correct"][task]]
                results["vs_" + ref][f"{name}/{task}/{key}"] = bootstrap(a, b)
    json.dump(results, open(args.output, "w"), indent=1)
    for key, (d, lo, hi) in results["vs_" + ref].items():
        print(f"{key:40s} {d:+6.2f} [{lo:+6.2f}, {hi:+6.2f}] points vs {ref}")


if __name__ == "__main__":
    main()

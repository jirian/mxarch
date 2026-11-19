"""Prepare the second perplexity text and the multiple-choice sets (run once, online).

- WikiText-2 raw validation, joined exactly as cli.py does ("\\n\\n"), so its
  SHA-256 matches the team's WikiText runs; read from the existing cache.
- ARC-Challenge test (all 1172) and a fixed 1000-item HellaSwag validation
  subset (seed 0), normalized to {context, choices, label} JSON lines.
Usage: python prepare_eval_data.py WIKITEXT_CACHE OUT_DIR
"""
import hashlib
import json
import os
import random
import re
import sys

from datasets import load_dataset

wikitext_cache, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)

wiki = load_dataset("Salesforce/wikitext", "wikitext-2-raw-v1", split="validation",
                    cache_dir=wikitext_cache)
text = "\n\n".join(wiki["text"])
with open(os.path.join(out, "wikitext-2-raw-v1-validation.txt"), "w", encoding="utf-8") as f:
    f.write(text)
print("wikitext sha256", hashlib.sha256(text.encode()).hexdigest())

arc = load_dataset("allenai/ai2_arc", "ARC-Challenge", split="test")
with open(os.path.join(out, "arc-challenge-test.jsonl"), "w") as f:
    for row in arc:
        labels = row["choices"]["label"]
        f.write(json.dumps({"id": row["id"],
                            "context": f"Question: {row['question']}\nAnswer:",
                            "choices": [" " + c for c in row["choices"]["text"]],
                            "label": labels.index(row["answerKey"])}) + "\n")
print("arc-challenge", len(arc))


def clean(s):
    # lm-evaluation-harness HellaSwag preprocessing.
    s = s.strip().replace(" [title]", ". ")
    s = re.sub(r"\[.*?\]", "", s)
    return s.replace("  ", " ")


hs = load_dataset("Rowan/hellaswag", split="validation")
idx = sorted(random.Random(0).sample(range(len(hs)), 1000))
with open(os.path.join(out, "hellaswag-validation-1000.jsonl"), "w") as f:
    for i in idx:
        row = hs[i]
        ctx = row["ctx_a"] + " " + row["ctx_b"].capitalize()
        f.write(json.dumps({"id": row["ind"],
                            "context": clean(row["activity_label"] + ": " + ctx),
                            "choices": [" " + clean(e) for e in row["endings"]],
                            "label": int(row["label"])}) + "\n")
print("hellaswag", len(idx))

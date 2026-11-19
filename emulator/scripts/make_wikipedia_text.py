"""Write a fixed English Wikipedia evaluation text (GPT-2's WebText excluded Wikipedia).

Avant-Garde evaluates GPT-2 on "English Wikipedia" without naming a dump or subset.
This selects the first --articles articles of at least --min-chars characters from
a pinned dump, in dataset order, and records provenance next to the text file.
"""
import argparse
import hashlib
import json
from pathlib import Path

from datasets import load_dataset


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--output", required=True)
    p.add_argument("--config", default="20231101.en")
    p.add_argument("--revision", default="main")
    p.add_argument("--articles", type=int, default=400)
    p.add_argument("--min-chars", type=int, default=8000)
    p.add_argument("--skip", type=int, default=0, help="Articles to skip before selection")
    args = p.parse_args()
    stream = load_dataset("wikimedia/wikipedia", args.config, split="train",
                          streaming=True, revision=args.revision)
    texts, ids = [], []
    for index, row in enumerate(stream):
        if index < args.skip or len(row["text"]) < args.min_chars:
            continue
        texts.append(row["text"].strip())
        ids.append(row["id"])
        if len(texts) == args.articles:
            break
    text = "\n\n".join(texts)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(text)
    source = {"dataset": "wikimedia/wikipedia", "config": args.config, "revision": args.revision,
              "split": "train", "articles": len(texts), "min_chars": args.min_chars,
              "skip": args.skip, "first_id": ids[0], "last_id": ids[-1],
              "characters": len(text), "text_sha256": hashlib.sha256(text.encode()).hexdigest()}
    output.with_suffix(".source.json").write_text(json.dumps(source, indent=2) + "\n")
    print(json.dumps(source, indent=2))


if __name__ == "__main__":
    main()

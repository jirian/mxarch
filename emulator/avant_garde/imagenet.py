"""Fetch only official ImageNet validation shards and materialize a fixed subset."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import random


def balanced_indices(labels, samples, seed):
    """Round-robin randomized classes: 1,000 samples gives one per ImageNet class."""
    if samples < 1 or samples > len(labels):
        raise ValueError("Requested subset size must be between 1 and dataset length")
    by_class = {}
    for index, label in enumerate(labels):
        if label < 0:
            raise ValueError("Validation labels must be nonnegative")
        by_class.setdefault(int(label), []).append(index)
    rng = random.Random(seed)
    classes = sorted(by_class)
    rng.shuffle(classes)
    for indices in by_class.values():
        rng.shuffle(indices)
    selected = []
    while len(selected) < samples:
        for label in classes:
            if by_class[label]:
                selected.append(by_class[label].pop())
                if len(selected) == samples:
                    break
    rng.shuffle(selected)
    return selected


def materialize(dataset, output_dir, samples, seed, source):
    output = Path(output_dir)
    images = output / "images"
    images.mkdir(parents=True, exist_ok=True)
    indices = balanced_indices(list(dataset["label"]), samples, seed)
    manifest = output / "validation.csv"
    temporary = output / "validation.csv.tmp"
    with temporary.open("w", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(["path", "label"])
        for index in indices:
            row = dataset[index]
            relative = f"images/{index:05d}.png"
            # Preserve decoded pixels; PNG avoids adding JPEG quantization error.
            row["image"].convert("RGB").save(output / relative)
            writer.writerow([relative, int(row["label"])])
    temporary.replace(manifest)
    features = getattr(dataset, "features", {})
    label_names = getattr(features.get("label"), "names", None)
    (output / "source.json").write_text(json.dumps({
        **source, "split": "validation", "samples": samples, "seed": seed,
        "url": "https://huggingface.co/datasets/ILSVRC/imagenet-1k",
        "manifest_sha256": hashlib.sha256(manifest.read_bytes()).hexdigest(),
        "selection": "class-balanced round robin", "indices": indices,
        "fingerprint": getattr(dataset, "_fingerprint", None), "label_names": label_names,
    }, indent=2) + "\n")
    return manifest


def prepare(output_dir, samples=1000, seed=0, revision="main", offline=False):
    from .cli import data_paths
    root = data_paths()
    from datasets import DownloadConfig, load_dataset
    from huggingface_hub import snapshot_download
    # Explicit patterns prevent downloading the much larger train/test splits.
    snapshot = Path(snapshot_download("ILSVRC/imagenet-1k", repo_type="dataset",
                                      revision=revision, local_files_only=offline,
                                      cache_dir=str(root / "huggingface" / "hub"),
                                      allow_patterns=["data/validation-*.parquet"]))
    shards = sorted(str(path) for path in (snapshot / "data").glob("validation-*.parquet"))
    if not shards:
        raise RuntimeError("No ImageNet validation shards in the requested snapshot")
    dataset = load_dataset("parquet", data_files={"validation": shards}, split="validation",
                           cache_dir=str(root / "datasets"),
                           download_config=DownloadConfig(local_files_only=offline))
    names = getattr(dataset.features.get("label"), "names", None)
    if names is None or len(names) != 1000:
        raise ValueError("Expected the official 1,000-class ImageNet label encoding")
    return materialize(dataset, output_dir, samples, seed, {
        "repo": "ILSVRC/imagenet-1k", "requested_revision": revision,
        "snapshot_commit": snapshot.name,
    })


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--samples", type=int, default=1000)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--revision", default="main")
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    print(prepare(args.output_dir, args.samples, args.seed, args.revision, args.offline), flush=True)


if __name__ == "__main__":
    main()

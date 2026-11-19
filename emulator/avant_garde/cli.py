import argparse
import csv
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import time

import torch

from .evaluation import classification, perplexity, token_windows
from .inference import MX9Inference, configure_fp32
from .mx9 import DEFAULT_MODES, MODES, MX9Config
from .tensor_core import ACCUMULATORS
from .uncertainty import add_uncertainty


def data_paths():
    root = Path(os.environ.get("AVANT_GARDE_DATA_ROOT", os.environ.get(
        "AVANT_GARDE_SCRATCH", "/work/cs-471/mixedprecisionarchitects/avant-garde-reproduction")))
    for name in ("HF_HOME", "HF_DATASETS_CACHE", "TMPDIR"):
        suffix = {"HF_HOME": "huggingface", "HF_DATASETS_CACHE": "datasets", "TMPDIR": "tmp"}[name]
        default = (Path(os.environ.get("AVANT_GARDE_TMP_ROOT", str(root / "tmp")))
                   if name == "TMPDIR" else root / suffix)
        os.environ.setdefault(name, str(default))
        Path(os.environ[name]).mkdir(parents=True, exist_ok=True)
    return root


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")
    temporary.replace(path)


def metadata(args):
    return {"arguments": vars(args), "python": platform.python_version(),
            "packages": {name: importlib.metadata.version(name)
                         for name in ("torch", "transformers", "datasets", "numpy", "Pillow")},
            "gpu": torch.cuda.get_device_name() if args.device == "cuda" else None,
            "slurm_job_id": os.environ.get("SLURM_JOB_ID"),
            "numerics": "docs/numerics.md; reconstructed assumptions, not author code"}


def tiny_vit(args):
    from transformers import ViTConfig, ViTForImageClassification
    torch.manual_seed(args.seed)
    model = ViTForImageClassification(ViTConfig(
        image_size=16, patch_size=4, num_channels=3, hidden_size=24,
        num_hidden_layers=2, num_attention_heads=3, intermediate_size=48,
        num_labels=7, attn_implementation="eager")).eval().to(args.device)
    pixels = torch.randn(2, 3, 16, 16, device=args.device)
    reports, outputs = [], {}
    for mode in args.modes:
        adapter = MX9Inference(model, mode, MX9Config(args.rounding, args.flattened_bits, flatten_rounding=args.flatten_rounding),
                               args.weights_only, backend=args.backend, exponent_overflow=args.exponent_overflow,
                               activation_policy=args.activation_policy, exempt=args.exempt,
                               exempt_mode=args.exempt_mode, accumulator=args.accumulator)
        with adapter.apply():
            result = model(pixel_values=pixels).logits
        adapter.check_coverage(1)
        if not bool(torch.isfinite(result).all()):
            raise RuntimeError(f"Nonfinite tiny ViT outputs in {mode}")
        outputs[mode] = result.cpu()
        reports.append({**adapter.report(), "logits": result.cpu().tolist()})
        del adapter
    if "mx9_hierarchical" in outputs and "mx9_lossless" in outputs:
        torch.testing.assert_close(outputs["mx9_hierarchical"], outputs["mx9_lossless"], rtol=0, atol=0)
    return {"experiment": "tiny_random_vit_forward", "runs": reports}


def gpt2(args):
    from transformers import AutoModelForCausalLM, AutoTokenizer
    tokenizer = AutoTokenizer.from_pretrained(args.model, revision=args.revision,
                                              local_files_only=args.offline)
    model = AutoModelForCausalLM.from_pretrained(
        args.model, revision=args.revision, local_files_only=args.offline,
        attn_implementation="eager", torch_dtype=torch.float32,
        device_map=args.device_map).eval()
    if args.device_map is None:
        model = model.to(args.device)
    if model.config.model_type not in ("gpt2", "qwen3", "qwen3_moe"):
        raise ValueError("This runner validates GPT-2 and Qwen3 (dense, MoE) models only")
    if args.context > model.config.max_position_embeddings:
        raise ValueError("Context exceeds checkpoint positional embedding capacity")
    if args.text_file:
        text = Path(args.text_file).read_text()
        dataset_info = {"path": str(Path(args.text_file).resolve())}
    else:
        from datasets import DownloadConfig, load_dataset
        dataset = load_dataset("Salesforce/wikitext", "wikitext-2-raw-v1",
                               split="validation", revision=args.dataset_revision,
                               download_config=DownloadConfig(local_files_only=args.offline))
        text = "\n\n".join(dataset["text"])
        dataset_info = {"name": "Salesforce/wikitext", "config": "wikitext-2-raw-v1",
                        "url": "https://huggingface.co/datasets/Salesforce/wikitext",
                        "split": "validation",
                        "revision": args.dataset_revision, "fingerprint": dataset._fingerprint}
    tokens = tokenizer(text, add_special_tokens=False, verbose=False)["input_ids"]
    windows = token_windows(tokens, args.context, args.windows)
    dataset_info["text_sha256"] = hashlib.sha256(text.encode()).hexdigest()
    dataset_info["scored_input_sha256"] = hashlib.sha256(
        torch.stack(windows).numpy().tobytes()).hexdigest()
    runs = []
    for mode in args.modes:
        print(f"GPT-2 {args.model} {mode}: {len(windows)} windows", flush=True)
        adapter = MX9Inference(model, mode, MX9Config(args.rounding, args.flattened_bits, flatten_rounding=args.flatten_rounding),
                               args.weights_only, backend=args.backend, exponent_overflow=args.exponent_overflow,
                               activation_policy=args.activation_policy, exempt=args.exempt,
                               exempt_mode=args.exempt_mode, accumulator=args.accumulator, cache_weights=not args.no_weight_cache)
        started = time.monotonic()
        with adapter.apply():
            metrics = perplexity(model, windows, args.device)
        adapter.check_coverage(len(windows))
        runs.append({**adapter.report(), "metrics": metrics,
                     "elapsed_seconds": time.monotonic() - started})
        del adapter
    by_mode = {run["mode"]: run["metrics"] for run in runs}
    if "mx9_hierarchical" in by_mode and "mx9_lossless" in by_mode:
        if by_mode["mx9_hierarchical"] != by_mode["mx9_lossless"]:
            raise RuntimeError("Hierarchical and lossless GPT-2 metrics differ")
    return {"experiment": "gpt2_perplexity", "model": args.model,
            "checkpoint_commit": getattr(model.config, "_commit_hash", None),
            "parameters": sum(p.numel() for p in model.parameters()),
            "dataset": dataset_info, "runs": runs}


def vit(args):
    from PIL import Image
    from transformers import AutoImageProcessor, ViTForImageClassification
    processor = AutoImageProcessor.from_pretrained(args.model, revision=args.revision,
                                                   local_files_only=args.offline)
    model = ViTForImageClassification.from_pretrained(
        args.model, revision=args.revision, local_files_only=args.offline,
        attn_implementation="eager", torch_dtype=torch.float32).eval().to(args.device)
    # An explicit manifest avoids silently assuming folder order == ImageNet IDs.
    manifest = Path(args.manifest)
    manifest_hash = hashlib.sha256(manifest.read_bytes()).hexdigest()
    dataset_source = {"manifest": str(manifest.resolve()), "manifest_sha256": manifest_hash}
    provenance = manifest.parent / "source.json"
    if provenance.is_file():
        source = json.loads(provenance.read_text())
        if source.get("manifest_sha256") != manifest_hash:
            raise ValueError("Dataset provenance does not match the ImageNet manifest")
        dataset_source["source"] = source
    rows = list(csv.DictReader(manifest.open()))[:args.samples]
    if not rows or not {"path", "label"}.issubset(rows[0]):
        raise ValueError("ImageNet manifest requires path,label columns and at least one row")
    def batches():
        for start in range(0, len(rows), args.batch_size):
            images, labels = [], []
            for row in rows[start:start + args.batch_size]:
                path = Path(row["path"])
                path = path if path.is_absolute() else manifest.parent / path
                with Image.open(path) as image:
                    images.append(image.convert("RGB"))
                label = int(row["label"])
                if not 0 <= label < model.config.num_labels:
                    raise ValueError("Manifest label outside checkpoint class range")
                labels.append(label)
            yield processor(images=images, return_tensors="pt")["pixel_values"], torch.tensor(labels)
    runs = []
    for mode in args.modes:
        print(f"ViT {args.model} {mode}: {len(rows)} images", flush=True)
        adapter = MX9Inference(model, mode, MX9Config(args.rounding, args.flattened_bits, flatten_rounding=args.flatten_rounding),
                               args.weights_only, backend=args.backend, exponent_overflow=args.exponent_overflow,
                               activation_policy=args.activation_policy, exempt=args.exempt,
                               exempt_mode=args.exempt_mode, accumulator=args.accumulator)
        with adapter.apply():
            metrics = classification(model, batches(), args.device)
        adapter.check_coverage((len(rows) + args.batch_size - 1) // args.batch_size)
        runs.append({**adapter.report(), "metrics": metrics})
        del adapter
    by_mode = {run["mode"]: run["metrics"] for run in runs}
    if "mx9_hierarchical" in by_mode and "mx9_lossless" in by_mode:
        if by_mode["mx9_hierarchical"] != by_mode["mx9_lossless"]:
            raise RuntimeError("Hierarchical and lossless ViT metrics differ")
    return {"experiment": "vit_accuracy", "model": args.model,
            "checkpoint_commit": getattr(model.config, "_commit_hash", None),
            "processor": processor.to_dict(),
            "parameters": sum(p.numel() for p in model.parameters()),
            "manifest_sha256": manifest_hash, "dataset": dataset_source, "runs": runs}


def sweep(args):
    spec = json.loads(Path(args.config).read_text())
    root = Path(args.output_dir)
    for model in spec["models"]:
        for context in spec.get("contexts", [None]):
            name = model.replace("/", "--") + (f"-ctx{context}" if context else "")
            command = [sys.executable, "-m", "avant_garde.cli", spec["command"],
                       "--model", model, "--device", args.device,
                       "--output", str(root / (name + ".json"))]
            if context:
                command += ["--context", str(context)]
            if "token_budget" in spec:
                if not context or spec["token_budget"] % context:
                    raise ValueError("token_budget must be divisible by every context length")
                command += ["--windows", str(spec["token_budget"] // context)]
            command += spec.get("arguments", []) + args.extra
            subprocess.run(command, check=True)


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    commands = p.add_subparsers(dest="command", required=True)
    for name in ("gpt2", "vit", "smoke-vit"):
        sub = commands.add_parser(name)
        sub.add_argument("--device", choices=("cpu", "cuda"), default="cpu")
        sub.add_argument("--modes", nargs="+", choices=MODES, default=list(DEFAULT_MODES))
        sub.add_argument("--rounding", choices=("even", "nearest", "trunc"), default="even")
        sub.add_argument("--flatten-rounding", choices=("even", "nearest", "trunc"), default="trunc",
                         help="Secondary-scale removal; trunc shifts signed magnitudes toward zero")
        sub.add_argument("--activation-policy", choices=("hierarchical", "fp32"), default="hierarchical",
                         help="Rebuild MX9 at activation boundaries, or keep FP32 between GEMMs")
        sub.add_argument("--flattened-bits", type=int, default=8)
        sub.add_argument("--backend", choices=("figure8", "dequantized"), default="figure8",
                         help="Explicit block dot/scale/accumulate, or the legacy FP32 GEMM")
        sub.add_argument("--accumulator", choices=ACCUMULATORS, default="fp32",
                         help="Figure 8 pipeline-register format (sensitivity setting)")
        sub.add_argument("--exponent-overflow", choices=("error", "wrap", "wide"), default="wide",
                         help="Retain mathematical exponent sums by default; error/wrap are sensitivity policies")
        sub.add_argument("--weights-only", action="store_true")
        sub.add_argument("--exempt", help="Regex of module names that use --exempt-mode")
        sub.add_argument("--exempt-mode", choices=MODES, default="mx9_hierarchical")
        sub.add_argument("--offline", action="store_true")
        sub.add_argument("--seed", type=int, default=0)
        sub.add_argument("--output", required=True)
        if name != "smoke-vit":
            sub.add_argument("--bootstrap-replicates", type=int, default=1000)
            sub.add_argument("--model", default="openai-community/gpt2" if name == "gpt2"
                             else "google/vit-base-patch16-224")
            sub.add_argument("--revision", default="main")
        if name == "gpt2":
            sub.add_argument("--text-file")
            sub.add_argument("--device-map", help="e.g. auto: spread a large model over GPUs")
            sub.add_argument("--no-weight-cache", action="store_true",
                             help="Re-quantize weights on each use instead of caching them")
            sub.add_argument("--dataset-revision", default="main")
            sub.add_argument("--context", type=int, default=128)
            sub.add_argument("--windows", type=int, default=32)
        if name == "vit":
            sub.add_argument("--manifest", required=True)
            sub.add_argument("--samples", type=int, default=100)
            sub.add_argument("--batch-size", type=int, default=8)
    sub = commands.add_parser("sweep")
    sub.add_argument("--config", required=True)
    sub.add_argument("--output-dir", required=True)
    sub.add_argument("--device", choices=("cpu", "cuda"), default="cuda")
    sub.add_argument("--extra", nargs=argparse.REMAINDER, default=[])
    return p


def main():
    args = parser().parse_args()
    if args.command == "sweep":
        sweep(args)
        return
    if args.device == "cuda" and not torch.cuda.is_available():
        raise RuntimeError("CUDA requested but unavailable; run inside a GPU allocation")
    if args.command == "vit" and (args.samples < 1 or args.batch_size < 1):
        raise ValueError("samples and batch-size must be positive")
    data_paths()
    if args.offline:
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["HF_DATASETS_OFFLINE"] = "1"
    configure_fp32()
    torch.manual_seed(args.seed)
    result = {"gpt2": gpt2, "vit": vit, "smoke-vit": tiny_vit}[args.command](args)
    if args.command != "smoke-vit":
        add_uncertainty(result["runs"], seed=args.seed, replicates=args.bootstrap_replicates)
    result["metadata"] = metadata(args)
    write_json(args.output, result)
    print(f"Results: {args.output}", flush=True)


if __name__ == "__main__":
    main()

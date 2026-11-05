"""Exercise real CLI loading/evaluation offline with tiny local checkpoints."""
import csv
import json
import sys

import torch
from PIL import Image
from tokenizers import Tokenizer
from tokenizers.models import WordLevel
from tokenizers.pre_tokenizers import Whitespace
from transformers import (GPT2Config, GPT2LMHeadModel, PreTrainedTokenizerFast,
                          ViTConfig, ViTForImageClassification, ViTImageProcessor)

from avant_garde.cli import main, parser, sweep
from avant_garde.summarize import rows, plot


def test_offline_local_runners_and_summary(tmp_path, monkeypatch):
    torch.set_num_threads(2)
    monkeypatch.setenv("AVANT_GARDE_SCRATCH", str(tmp_path / "scratch"))
    for variable in ("HF_HOME", "HF_DATASETS_CACHE", "TMPDIR", "HF_HUB_OFFLINE", "HF_DATASETS_OFFLINE"):
        monkeypatch.setenv(variable, str(tmp_path / variable) if "OFFLINE" not in variable else "1")
    gpt_dir = tmp_path / "gpt"
    GPT2LMHeadModel(GPT2Config(vocab_size=12, n_positions=32, n_embd=16,
                              n_layer=1, n_head=2)).save_pretrained(gpt_dir)
    tokenizer = Tokenizer(WordLevel({"[UNK]": 0, **{f"word{i}": i + 1 for i in range(11)}},
                                    unk_token="[UNK]"))
    tokenizer.pre_tokenizer = Whitespace()
    PreTrainedTokenizerFast(tokenizer_object=tokenizer, unk_token="[UNK]").save_pretrained(gpt_dir)
    text = tmp_path / "text.txt"
    text.write_text(" ".join(f"word{i % 11}" for i in range(32)))
    gpt_out = tmp_path / "gpt.json"
    monkeypatch.setattr(sys, "argv", ["avant-garde", "gpt2", "--model", str(gpt_dir),
                                     "--text-file", str(text), "--context", "8", "--windows", "2",
                                     "--offline", "--output", str(gpt_out)])
    main()
    report = json.loads(gpt_out.read_text())
    assert len(report["runs"]) == 4
    assert all("perplexity_std" in run["uncertainty"] for run in report["runs"])
    assert all(run["metrics"]["scored_tokens"] == 14 for run in report["runs"])
    modes = {run["mode"]: run["metrics"] for run in report["runs"]}
    assert modes["mx9_hierarchical"] == modes["mx9_lossless"]
    vit_dir = tmp_path / "vit"
    ViTForImageClassification(ViTConfig(image_size=16, patch_size=4, hidden_size=16,
                                       num_hidden_layers=1, num_attention_heads=2,
                                       intermediate_size=32, num_labels=7)).save_pretrained(vit_dir)
    ViTImageProcessor(size={"height": 16, "width": 16}).save_pretrained(vit_dir)
    Image.new("RGB", (20, 20), color="red").save(tmp_path / "image.png")
    manifest = tmp_path / "images.csv"
    manifest.write_text("path,label\nimage.png,1\n")
    vit_out = tmp_path / "vit.json"
    monkeypatch.setattr(sys, "argv", ["avant-garde", "vit", "--model", str(vit_dir),
                                     "--manifest", str(manifest), "--offline", "--output", str(vit_out)])
    main()
    data = rows([gpt_out, vit_out])
    assert all("std" in row and "normalized_std" in row for row in data)
    assert len(data) == 8
    assert all(row["degradation_vs_fp32"] == 0 for row in data if row["mode"] == "fp32")
    assert all(row["degradation_vs_hierarchical"] == 0 for row in data if row["mode"] == "mx9_lossless")
    # Optional plotting dependency is present in the validation environment.
    import importlib.util
    if importlib.util.find_spec("matplotlib"):
        plot(data, tmp_path / "comparison.png")
        assert (tmp_path / "comparison.png").stat().st_size > 0


def test_sweep_forwards_arguments(tmp_path, monkeypatch):
    config = tmp_path / "config.json"
    config.write_text(json.dumps({"command": "vit", "models": ["base", "large"]}))
    calls = []
    monkeypatch.setattr("avant_garde.cli.subprocess.run", lambda command, check: calls.append(command))
    args = parser().parse_args(["sweep", "--config", str(config), "--output-dir", str(tmp_path),
                                "--extra", "--manifest", "images.csv", "--offline"])
    sweep(args)
    assert len(calls) == 2
    assert all(command[-3:] == ["--manifest", "images.csv", "--offline"] for command in calls)


def test_context_sweep_preserves_input_token_budget(tmp_path, monkeypatch):
    from pathlib import Path
    calls = []
    monkeypatch.setattr("avant_garde.cli.subprocess.run", lambda command, check: calls.append(command))
    config = Path(__file__).resolve().parents[1] / "configs/gpt2_context.json"
    args = parser().parse_args(["sweep", "--config", str(config), "--output-dir", str(tmp_path)])
    sweep(args)
    assert len(calls) == 12
    for command in calls:
        context = int(command[command.index("--context") + 1])
        windows = int(command[command.index("--windows") + 1])
        assert context in (128, 512, 1024)
        assert context * windows == 32768

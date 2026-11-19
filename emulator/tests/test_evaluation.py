import json
from types import SimpleNamespace

import pytest
import torch

from avant_garde.cli import parser, write_json
from avant_garde.evaluation import classification, perplexity, token_windows


def test_windows_and_token_weighted_perplexity():
    windows = token_windows(list(range(20)), 6, 3)
    assert [w.tolist() for w in windows] == [list(range(i, i + 6)) for i in (0, 6, 12)]
    class Uniform:
        def __call__(self, input_ids, use_cache):
            return SimpleNamespace(logits=torch.zeros(*input_ids.shape, 20))
    metrics = perplexity(Uniform(), windows, "cpu")
    assert metrics["scored_tokens"] == 15
    assert metrics["perplexity"] == pytest.approx(20)
    with pytest.raises(ValueError):
        token_windows([1], 8, 1)
    with pytest.raises(ValueError):
        token_windows([1], 1, 1)


def test_classification_and_serialization(tmp_path):
    class Identity:
        def __call__(self, pixel_values):
            return SimpleNamespace(logits=pixel_values)
    metrics = classification(Identity(), [(torch.eye(7), torch.arange(7))], "cpu")
    assert {key: metrics[key] for key in ("top1_percent", "top5_percent", "samples")} == {
        "top1_percent": 100, "top5_percent": 100, "samples": 7}
    assert metrics["observations"]["top1_correct"] == [True] * 7
    path = tmp_path / "nested" / "result.json"
    write_json(path, metrics)
    assert json.loads(path.read_text()) == metrics
    with pytest.raises(ValueError):
        write_json(path, {"value": float("nan")})


def test_cli():
    args = parser().parse_args(["gpt2", "--output", "x.json"])
    assert args.context == 128 and args.windows == 32 and len(args.modes) == 4
    with pytest.raises(SystemExit):
        parser().parse_args(["gpt2", "--modes", "wrong", "--output", "x.json"])

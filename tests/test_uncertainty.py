import math

import pytest

from avant_garde.uncertainty import add_uncertainty


def test_paired_bootstrap_perplexity_uses_token_weighted_loss():
    obs = {"unit": "text_window", "loss_sums": [0., 3 * math.log(4)], "token_counts": [1, 3]}
    runs = [{"mode": mode, "metrics": {"observations": obs}}
            for mode in ("fp32", "mx9_hierarchical")]
    add_uncertainty(runs, seed=0, replicates=5000)
    # Two draws produce metrics 1, 4**.75, 4 with probabilities .25,.5,.25.
    mean = .25 + .5 * 4 ** .75 + 1
    expected = math.sqrt(.25 * (1 - mean) ** 2 + .5 * (4 ** .75 - mean) ** 2 + .25 * (4 - mean) ** 2)
    assert runs[0]["uncertainty"]["perplexity_std"] == pytest.approx(expected, rel=.04)
    assert runs[1]["uncertainty"]["perplexity_normalized_std"] == 0
    prior = runs[0]["uncertainty"].copy()
    add_uncertainty(runs, seed=0, replicates=5000)
    assert runs[0]["uncertainty"] == prior


def test_bootstrap_accuracy_and_zero_denominator():
    runs = [{"mode": mode, "metrics": {"observations": {
        "unit": "image", "top1_correct": correctness, "top5_correct": [1] * 4}}}
        for mode, correctness in [("fp32", [1] * 4), ("mx9_flattened", [0, 0, 1, 1])]]
    add_uncertainty(runs, seed=1, replicates=5000)
    stats = runs[1]["uncertainty"]
    assert stats["top1_percent_std"] == pytest.approx(25, rel=.05)
    assert stats["top1_percent_normalized_std"] == pytest.approx(.25, rel=.05)
    assert stats["top5_percent_std"] == 0
    runs[0]["metrics"]["observations"]["top1_correct"] = [0] * 4
    add_uncertainty(runs, seed=1, replicates=20)
    assert runs[1]["uncertainty"]["top1_percent_normalized_std"] is None
    assert runs[1]["uncertainty"]["top1_percent_zero_baseline_replicates"] == 20


def test_invalid_bootstrap():
    with pytest.raises(ValueError):
        add_uncertainty([], replicates=1)

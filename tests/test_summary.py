import json

import pytest

from avant_garde.summarize import rows, bar_figure


def report(path, metric, values):
    path.write_text(json.dumps({
        "experiment": "gpt2_perplexity" if metric == "perplexity" else "vit_accuracy",
        "model": "gpt2" if metric == "perplexity" else "vit-base",
        "parameters": 124000000,
        "metadata": {"arguments": {"context": 128} if metric == "perplexity" else {}},
        "runs": [{"mode": mode, "metrics": {metric: value}, "diagnostics": {}}
                 for mode, value in zip(
                     ("fp32", "mx9_hierarchical", "mx9_flattened", "mx9_lossless"), values)]}))


def test_normalization_and_bar_heights(tmp_path):
    pytest.importorskip("matplotlib")
    gpt, vit = tmp_path / "gpt.json", tmp_path / "vit.json"
    report(gpt, "perplexity", [20, 21, 22, 21])
    report(vit, "top1_percent", [80, 78, 76, 78])
    data = rows([gpt, vit])
    for row in data:
        if row["metric"] == "perplexity" and row["mode"] == "mx9_flattened":
            row["normalized_std"] = .03
    fig = bar_figure(data)
    assert len(fig.axes) == 2
    # Each panel has three series; the lossless control is excluded.
    assert [p.get_height() for p in fig.axes[0].patches] == pytest.approx([1, 1.05, 1.1])
    assert [p.get_height() for p in fig.axes[1].patches] == pytest.approx([1, .975, .95])
    assert all(ax.get_ylim()[0] == 0 for ax in fig.axes)
    segment = fig.axes[0].collections[0].get_segments()[0]
    assert segment[:, 1] == pytest.approx([1.07, 1.13])
    import matplotlib.pyplot as plt
    plt.close(fig)


def test_zero_baseline_is_undefined(tmp_path):
    pytest.importorskip("matplotlib")
    path = tmp_path / "zero.json"
    report(path, "top1_percent", [0, 1, 2, 1])
    data = rows([path])
    assert all(row["normalized_to_fp32"] is None for row in data)
    fig = bar_figure(data)
    assert sum(text.get_text() == "N/A" for text in fig.axes[0].texts) == 3
    import matplotlib.pyplot as plt
    plt.close(fig)

import csv
import json

import pytest
from PIL import Image

from avant_garde.imagenet import balanced_indices, prepare


def test_balanced_indices():
    labels = [0] * 10 + [1] * 10 + [2] * 10
    indices = balanced_indices(labels, 6, 42)
    assert indices == balanced_indices(labels, 6, 42)
    assert len(set(indices)) == 6
    assert [sum(labels[i] == c for i in indices) for c in range(3)] == [2, 2, 2]
    assert sorted(balanced_indices([0, 0, 1], 3, 0)) == [0, 1, 2]
    for count in (0, 31):
        with pytest.raises(ValueError):
            balanced_indices(labels, count, 0)


def test_prepare_offline_parquet_fixture(tmp_path, monkeypatch):
    from datasets import ClassLabel, Dataset, Features, Image as HFImage
    monkeypatch.setenv("AVANT_GARDE_DATA_ROOT", str(tmp_path / "data"))
    monkeypatch.setenv("TMPDIR", str(tmp_path / "tmp"))
    for variable in ("HF_HOME", "HF_DATASETS_CACHE"):
        monkeypatch.delenv(variable, raising=False)
    snapshot = tmp_path / ("a" * 40)
    (snapshot / "data").mkdir(parents=True)
    dataset = Dataset.from_dict({"image": [Image.new("RGB", (8, 8), color="red")] * 6,
                                 "label": [0, 0, 1, 1, 2, 2]}, features=Features({
                                     "image": HFImage(), "label": ClassLabel(num_classes=1000)}))
    dataset.to_parquet(snapshot / "data" / "validation-00000.parquet")
    calls = []
    def download(repo, **kwargs):
        calls.append((repo, kwargs))
        return str(snapshot)
    monkeypatch.setattr("huggingface_hub.snapshot_download", download)
    output = tmp_path / "subset"
    manifest = prepare(output, samples=3, seed=0, offline=True)
    assert calls[0][1]["allow_patterns"] == ["data/validation-*.parquet"]
    assert calls[0][1]["local_files_only"] is True
    with manifest.open() as stream:
        rows = list(csv.DictReader(stream))
    assert sorted(int(row["label"]) for row in rows) == [0, 1, 2]
    assert all((output / row["path"]).is_file() for row in rows)
    source = json.loads((output / "source.json").read_text())
    assert source["snapshot_commit"] == "a" * 40
    assert len(source["label_names"]) == 1000

"""CPU-only orchestration checks: never call sbatch or execute CUDA code."""
import json
import os
from pathlib import Path
import subprocess

from avant_garde.cli import data_paths


def test_data_root_precedence_and_legacy_override(tmp_path, monkeypatch):
    for name in ("HF_HOME", "HF_DATASETS_CACHE", "TMPDIR", "AVANT_GARDE_DATA_ROOT"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("TMPDIR", str(tmp_path / "temporary"))
    monkeypatch.setenv("AVANT_GARDE_SCRATCH", str(tmp_path / "legacy"))
    assert data_paths() == tmp_path / "legacy"
    assert Path(os.environ["HF_HOME"]) == tmp_path / "legacy" / "huggingface"
    monkeypatch.setenv("AVANT_GARDE_DATA_ROOT", str(tmp_path / "work"))
    for name in ("HF_HOME", "HF_DATASETS_CACHE"):
        monkeypatch.delenv(name)
    assert data_paths() == tmp_path / "work"
    assert Path(os.environ["HF_HOME"]) == tmp_path / "work" / "huggingface"


def test_size_job_orchestration_without_gpu(tmp_path):
    interpreter = tmp_path / "mock-python"
    interpreter.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
assert os.environ.get("HF_TOKEN_PATH") == os.environ["EXPECTED_TOKEN_PATH"]
with open(os.environ["MOCK_CALLS"], "a") as stream:
    stream.write(json.dumps(args) + "\\n")
if "sweep" in args:
    config = json.loads(pathlib.Path(args[args.index("--config") + 1]).read_text())
    root = pathlib.Path(args[args.index("--output-dir") + 1])
    root.mkdir(parents=True)
    for i, model in enumerate(config["models"]):
        (root / f"{i}.json").write_text("{}")
elif "avant_garde.imagenet" in args:
    if os.environ.get("MOCK_DOWNLOAD_FAIL") == "1":
        sys.exit(7)
    root = pathlib.Path(args[args.index("--output-dir") + 1])
    root.mkdir(parents=True)
    (root / "validation.csv").write_text("path,label\\nimage.png,0\\n")
''')
    interpreter.chmod(0o755)
    calls = tmp_path / "calls.jsonl"
    token_dir = tmp_path / "prior-hf"
    token_dir.mkdir()
    (token_dir / "token").write_text("non-secret-test-placeholder")
    env = {**os.environ, "AVANT_GARDE_PYTHON": str(interpreter),
           "SLURM_SUBMIT_DIR": str(Path(__file__).resolve().parents[1]),
           "SLURM_JOB_ID": "test", "SLURM_CPUS_PER_TASK": "6",
           "AVANT_GARDE_DATA_ROOT": str(tmp_path / "work"),
           "AVANT_GARDE_TMP_ROOT": str(tmp_path / "tmp"),
           "AVANT_GARDE_FAMILIES": "both", "AVANT_GARDE_OFFLINE": "1", "MOCK_CALLS": str(calls),
           "HF_HOME": str(token_dir), "EXPECTED_TOKEN_PATH": str(token_dir / "token")}
    env.pop("HF_TOKEN_PATH", None)
    env.pop("AVANT_GARDE_GPT2_RESULTS", None)
    env.pop("AVANT_GARDE_IMAGENET_MANIFEST", None)
    job = ["bash", "scripts/slurm/model_size_l40s.sbatch"]
    subprocess.run(job, cwd=env["SLURM_SUBMIT_DIR"], env=env, check=True)
    recorded = [json.loads(line) for line in calls.read_text().splitlines()]
    assert len(recorded) == 5
    assert "configs/gpt2_size.json" in recorded[1] and "--offline" in recorded[1]
    assert "avant_garde.imagenet" in recorded[2]
    assert "configs/vit_size.json" in recorded[3] and "--manifest" in recorded[3]
    assert len([arg for arg in recorded[4] if arg.endswith(".json")]) == 6
    calls.unlink()
    env["AVANT_GARDE_FAMILIES"] = "gpt2"
    env["SLURM_JOB_ID"] = "gpt-only"
    subprocess.run(job, cwd=env["SLURM_SUBMIT_DIR"], env=env, check=True)
    recorded = [json.loads(line) for line in calls.read_text().splitlines()]
    assert len(recorded) == 3
    assert len([arg for arg in recorded[-1] if arg.endswith(".json")]) == 4
    calls.unlink()
    env["AVANT_GARDE_FAMILIES"] = "both"
    env["SLURM_JOB_ID"] = "failed-download"
    env["MOCK_DOWNLOAD_FAIL"] = "1"
    result = subprocess.run(job, cwd=env["SLURM_SUBMIT_DIR"], env=env)
    assert result.returncode == 7
    recorded = [json.loads(line) for line in calls.read_text().splitlines()]
    assert "avant_garde.summarize" in recorded[-1]
    assert len([arg for arg in recorded[-1] if arg.endswith(".json")]) == 4

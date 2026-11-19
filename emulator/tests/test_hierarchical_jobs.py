"""Validate new array/summary orchestration without submitting jobs or using CUDA."""
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest


@pytest.fixture
def job_env(tmp_path):
    interpreter = tmp_path / "mock-python"
    interpreter.write_text(f"#!{sys.executable}\n" + '''import json, os, sys
with open(os.environ["MOCK_CALLS"], "a") as stream:
    stream.write(json.dumps(sys.argv[1:]) + "\\n")
''')
    interpreter.chmod(0o755)
    manifest = tmp_path / "validation.csv"
    manifest.write_text("path,label\nimage.png,0\n")
    return {**os.environ, "AVANT_GARDE_PYTHON": str(interpreter),
            "SLURM_SUBMIT_DIR": str(Path(__file__).resolve().parents[1]),
            "SLURM_JOB_ID": "cpu-test", "SLURM_ARRAY_JOB_ID": "1234",
            "AVANT_GARDE_DATA_ROOT": str(tmp_path / "data"),
            "AVANT_GARDE_TMP_ROOT": str(tmp_path / "tmp"),
            "AVANT_GARDE_IMAGENET_MANIFEST": str(manifest),
            "AVANT_GARDE_OFFLINE": "1", "MOCK_CALLS": str(tmp_path / "calls")}


@pytest.mark.parametrize("task,model,context", [(0, "gpt2", 128), (2, "gpt2", 1024),
    (5, "gpt2-medium", 1024), (11, "gpt2-xl", 1024),
    (12, "vit-base-patch16-224", None), (13, "vit-large-patch16-224", None)])
def test_array_mapping_and_numerical_flags(job_env, task, model, context):
    env = {**job_env, "SLURM_ARRAY_TASK_ID": str(task)}
    subprocess.run(["bash", "scripts/slurm/hierarchical_sweep_l40s.sbatch"], env=env,
                   cwd=env["SLURM_SUBMIT_DIR"], check=True)
    commands = [json.loads(line) for line in Path(env["MOCK_CALLS"]).read_text().splitlines()]
    command = commands[0]
    assert command[command.index("--model") + 1].endswith("/" + model)
    for name, expected in (("--backend", "figure8"), ("--rounding", "even"),
                           ("--flatten-rounding", "trunc"), ("--activation-policy", "hierarchical"),
                           ("--exponent-overflow", "wide")):
        assert command[command.index(name) + 1] == expected
    assert "--offline" in command
    if context:
        assert int(command[command.index("--context") + 1]) == context
        assert int(command[command.index("--windows") + 1]) * context == 32768
    else:
        assert command[command.index("--samples") + 1] == "1000"
    assert "avant_garde.summarize" in commands[1] and "--plot" in commands[1]


def test_partial_summary_writes_plots_but_reports_incomplete(job_env):
    root = Path(job_env["AVANT_GARDE_DATA_ROOT"]) / "runs/hierarchical-1234/gpt2"
    root.mkdir(parents=True)
    (root / "partial.json").write_text("{}")
    command = ["bash", "scripts/slurm/hierarchical_summary.sbatch", "1234"]
    result = subprocess.run(command, env=job_env, cwd=job_env["SLURM_SUBMIT_DIR"])
    assert result.returncode == 1
    recorded = json.loads(Path(job_env["MOCK_CALLS"]).read_text().splitlines()[0])
    assert "--plot" in recorded and str(root / "partial.json") in recorded
    for i in range(13):
        (root / f"{i}.json").write_text("{}")
    subprocess.run(command, env=job_env, cwd=job_env["SLURM_SUBMIT_DIR"], check=True)

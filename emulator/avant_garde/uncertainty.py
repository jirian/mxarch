"""Paired bootstrap uncertainty over evaluation windows or images."""
import numpy as np


def add_uncertainty(runs, seed=0, replicates=1000):
    if replicates < 2 or not runs:
        raise ValueError("Need evaluation runs and at least two bootstrap replicates")
    unit = runs[0]["metrics"]["observations"]["unit"]
    fields = ("loss_sums", "token_counts") if unit == "text_window" else ("top1_correct", "top5_correct")
    arrays, size = {}, None
    for run in runs:
        obs = run["metrics"]["observations"]
        if obs["unit"] != unit:
            raise ValueError("Bootstrap units must match across modes")
        arrays[run["mode"]] = [np.asarray(obs[field], dtype=np.float64) for field in fields]
        lengths = {len(a) for a in arrays[run["mode"]]}
        if len(lengths) != 1 or not next(iter(lengths)):
            raise ValueError("Empty or inconsistent observation arrays")
        n = next(iter(lengths))
        if size is not None and size != n:
            raise ValueError("Paired modes must use the same observations")
        size = n
    rng = np.random.default_rng(seed)
    names = ("perplexity",) if unit == "text_window" else ("top1_percent", "top5_percent")
    draws = {mode: {name: [] for name in names} for mode in arrays}
    for start in range(0, replicates, 64):
        indices = rng.integers(size, size=(min(64, replicates - start), size))
        for mode, (first, second) in arrays.items():
            if unit == "text_window":
                denominators = second[indices].sum(axis=1)
                if np.any(denominators <= 0):
                    raise ValueError("Window token counts must be positive")
                draws[mode]["perplexity"].extend(np.exp(first[indices].sum(axis=1) / denominators))
            else:
                draws[mode]["top1_percent"].extend(first[indices].mean(axis=1) * 100)
                draws[mode]["top5_percent"].extend(second[indices].mean(axis=1) * 100)
    for run in runs:
        mode = run["mode"]
        info = {"method": "paired_bootstrap", "unit": unit, "observations": size,
                "replicates": replicates, "seed": seed}
        for metric, values in draws[mode].items():
            values = np.asarray(values)
            if not np.isfinite(values).all():
                raise ValueError("Nonfinite bootstrap metric")
            info[metric + "_std"] = float(values.std(ddof=1))
            if "fp32" in draws:
                baseline = np.asarray(draws["fp32"][metric])
                zero_count = int((baseline == 0).sum())
                info[metric + "_normalized_std"] = (
                    float((values / baseline).std(ddof=1)) if not zero_count else None)
                info[metric + "_zero_baseline_replicates"] = zero_count
        run["uncertainty"] = info

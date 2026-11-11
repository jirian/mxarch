"""Export paired metrics and bar graphs normalized to unquantized FP32."""
import argparse
import csv
import json
from pathlib import Path


def rows(paths):
    result = []
    for path in paths:
        report = json.loads(Path(path).read_text())
        if report["experiment"] not in ("gpt2_perplexity", "vit_accuracy"):
            continue
        runs = {run["mode"]: run for run in report["runs"]}
        metric = "perplexity" if report["experiment"] == "gpt2_perplexity" else "top1_percent"
        sign = 1 if metric == "perplexity" else -1
        baseline = runs["fp32"]["metrics"][metric]
        hierarchical = runs["mx9_hierarchical"]["metrics"][metric]
        for mode, run in runs.items():
            value = run["metrics"][metric]
            stats = [s for key, s in run["diagnostics"].items() if key.endswith(":flatten")]
            result.append({
                "source": str(path), "model": report["model"], "parameters": report["parameters"],
                "context": report["metadata"]["arguments"].get("context", ""),
                "mode": mode, "metric": metric, "value": value,
                "numerical_backend": run.get("numerical_backend", "native_fp32" if mode == "fp32" else "dequantized"),
                "numerical_contract": run.get("numerical_contract", "native-fp32-v1" if mode == "fp32" else "dequantized-gemm-v1"),
                "exponent_overflow": run.get("exponent_overflow"),
                "activation_policy": run.get("activation_policy", "fp32"),
                "flatten_rounding": run.get("config", {}).get("flatten_rounding", run.get("config", {}).get("rounding", "even")),
                "normalized_to_fp32": value / baseline if baseline else None,
                "std": run.get("uncertainty", {}).get(metric + "_std"),
                "normalized_std": run.get("uncertainty", {}).get(metric + "_normalized_std"),
                "weights_only": report["metadata"]["arguments"].get("weights_only", False),
                "degradation_vs_fp32": sign * (value - baseline),
                "degradation_vs_hierarchical": sign * (value - hierarchical),
                "relative_degradation_vs_fp32_percent": sign * (value / baseline - 1) * 100
                    if baseline else "",
                **{f"flatten_{name}": sum(s[name] for s in stats)
                   for name in ("rounding_changed", "rounded_to_zero", "out_of_range", "saturated")},
            })
    return result


def bar_figure(data):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    series = [("fp32", "FP32 (unquantized)", "#999999"),
              ("mx9_hierarchical", "MX9 (not flattened)", "#4477AA"),
              ("mx9_flattened", "MX9 (flattened)", "#EE7733")]
    selected = [r for r in data if r["mode"] in {mode for mode, _, _ in series}]
    metrics = sorted({r["metric"] for r in selected})
    if not metrics:
        raise ValueError("No FP32/hierarchical/flattened evaluation metrics to plot")
    max_groups = max(len({r["source"] for r in selected if r["metric"] == metric})
                     for metric in metrics)
    fig, axes = plt.subplots(len(metrics), 1, squeeze=False,
                             figsize=(max(8, max_groups * 1.5), 4.5 * len(metrics)))
    for i, metric in enumerate(metrics):
        ax = axes[i, 0]
        grouped = {}
        for row in selected:
            if row["metric"] == metric:
                grouped.setdefault(row["source"], {})[row["mode"]] = row
        groups = sorted(grouped.values(), key=lambda g: (
            next(iter(g.values()))["parameters"],
            next(iter(g.values()))["model"],
            next(iter(g.values()))["context"] or 0))
        labels = []
        for group in groups:
            row = next(iter(group.values()))
            label = row["model"].rsplit("/", 1)[-1]
            if row["context"] != "":
                label += f"\ncontext {row['context']}"
            label += "\nweights only" if row["weights_only"] else "\nweights + activations"
            quantized = group.get("mx9_flattened", group.get("mx9_hierarchical", row))
            label += "\n" + quantized.get("numerical_backend", "dequantized")
            if quantized.get("numerical_backend") == "figure8":
                label += f" ({quantized.get('exponent_overflow', 'error')})"
            label += f"\nactivations: {quantized.get('activation_policy', 'fp32')}"
            label += f"; flatten: {quantized.get('flatten_rounding', 'even')}"
            labels.append(label)
        for j, (mode, label, color) in enumerate(series):
            positions = [k + (j - 1) * .25 for k in range(len(groups))]
            values = [group.get(mode, {}).get("normalized_to_fp32") for group in groups]
            bars = ax.bar(positions, [v if v is not None else float("nan") for v in values],
                          width=.24, label=label, color=color, edgecolor="black", linewidth=.4)
            errors = [group.get(mode, {}).get("normalized_std") for group in groups]
            error_points = [(x, v, e) for x, v, e in zip(positions, values, errors)
                            if v is not None and e is not None]
            if error_points:
                x, y, error = zip(*error_points)
                ax.errorbar(x, y, yerr=error, fmt="none", ecolor="black", capsize=3, linewidth=1)
            for bar, value, position, error in zip(bars, values, positions, errors):
                if value is None:
                    ax.text(position, .02, "N/A", ha="center", fontsize=7, rotation=90)
                else:
                    ax.annotate(f"{value:.4f}", (bar.get_x() + bar.get_width() / 2, value + (error or 0)),
                                xytext=(0, 4), textcoords="offset points", ha="center", fontsize=7,
                                rotation=90 if len(groups) > 4 else 0)
        title = "Perplexity (lower is better)" if metric == "perplexity" else "Top-1 accuracy (higher is better)"
        if any(r.get("normalized_std") is not None for r in selected if r["metric"] == metric):
            title += "\nError bars: ±1 paired bootstrap SD"
        ax.set_title(title)
        ax.set_ylabel("Metric / unquantized FP32")
        ax.set_xticks(range(len(groups)), labels, rotation=30 if len(groups) > 4 else 0,
                      ha="right" if len(groups) > 4 else "center")
        ax.set_xlim(-.6, len(groups) - .4)
        ax.axhline(1, color="black", linestyle="--", linewidth=.8)
        ax.set_ylim(bottom=0)
        ax.margins(y=.2)
        ax.set_axisbelow(True)
        ax.grid(axis="y", alpha=.2)
        ax.legend(fontsize=8)
    fig.tight_layout()
    return fig


def plot(data, output):
    fig = bar_figure(data)
    import matplotlib.pyplot as plt
    fig.savefig(output, dpi=160)
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+")
    parser.add_argument("--csv", required=True)
    parser.add_argument("--plot")
    args = parser.parse_args()
    data = rows(args.reports)
    if not data:
        raise ValueError("No evaluation reports")
    destination = Path(args.csv)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(data[0]))
        writer.writeheader()
        writer.writerows(data)
    if args.plot:
        Path(args.plot).parent.mkdir(parents=True, exist_ok=True)
        plot(data, args.plot)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3

import csv
import statistics
import sys
from collections import defaultdict
from pathlib import Path


def load_rows(path: Path) -> list[dict]:
    rows = []
    with path.open("r", encoding="utf-8") as handle:
        filtered = [
            line
            for line in handle
            if line.strip()
            and not line.startswith("#")
            and line.count(",") >= 6
        ]
    reader = csv.DictReader(filtered)
    for row in reader:
        if not row.get("total_workload") or not row.get("elapsed_us"):
            continue
        rows.append(
            {
                "language": row["language"],
                "benchmark": row["benchmark"],
                "total_workload": int(row["total_workload"]),
                "task_count": int(row["task_count"]),
                "iteration": int(row["iteration"]),
                "elapsed_us": int(row["elapsed_us"]),
                "checksum": int(row["checksum"]),
                "source": str(path),
            }
        )
    return rows


TRIM_COUNT = 2


def summarize(rows: list[dict]) -> dict[tuple[str, str, int], dict]:
    grouped: dict[tuple[str, str, int], list[int]] = defaultdict(list)
    for row in rows:
        key = (row["language"], row["benchmark"], row["task_count"])
        grouped[key].append(row["elapsed_us"])

    summary: dict[tuple[str, str, int], dict] = {}
    for key, samples in grouped.items():
        sorted_samples = sorted(samples)
        if len(sorted_samples) > TRIM_COUNT * 2:
            trimmed = sorted_samples[TRIM_COUNT : len(sorted_samples) - TRIM_COUNT]
        else:
            trimmed = sorted_samples
        summary[key] = {
            "count": len(samples),
            "trimmed_count": len(trimmed),
            "average_us": int(sum(trimmed) / len(trimmed)),
            "median_us": int(statistics.median(trimmed)),
            "min_us": min(trimmed),
            "max_us": max(trimmed),
        }
    return summary


def print_table(title: str, headers: list[str], rows: list[list[str]]) -> None:
    widths = [len(header) for header in headers]
    for row in rows:
        for index, cell in enumerate(row):
            widths[index] = max(widths[index], len(cell))

    border = "+" + "+".join("-" * (width + 2) for width in widths) + "+"

    print(title)
    print(border)
    print("| " + " | ".join(header.ljust(widths[index]) for index, header in enumerate(headers)) + " |")
    print(border)
    for row in rows:
        print("| " + " | ".join(cell.ljust(widths[index]) for index, cell in enumerate(row)) + " |")
    print(border)


def print_language_breakdown(summary: dict[tuple[str, str, int], dict]) -> None:
    rows: list[list[str]] = []
    for key in sorted(summary):
        language, benchmark, task_count = key
        metrics = summary[key]
        rows.append(
            [
                language,
                benchmark,
                str(task_count),
                f"{metrics['median_us']}us",
                f"{metrics['average_us']}us",
                f"{metrics['min_us']}us",
                f"{metrics['max_us']}us",
            ]
        )
    print_table(
        "Per-language benchmark summary",
        ["language", "benchmark", "task_count", "median", "avg", "min", "max"],
        rows,
    )


def print_within_language_speedups(summary: dict[tuple[str, str, int], dict]) -> None:
    rows: list[list[str]] = []
    languages = sorted({key[0] for key in summary})
    for language in languages:
        sequential_key = "sequential_baseline"
        baseline = summary.get((language, sequential_key, 1))
        if baseline is None:
            continue
        structured_candidates = [
            key for key in summary if key[0] == language and key[1] != sequential_key and key[1] != "spawn_overhead"
        ]
        for candidate in sorted(structured_candidates, key=lambda item: (item[1], item[2])):
            structured_benchmark = candidate[1]
            task_count = candidate[2]
            structured = summary[candidate]
            speedup = baseline["median_us"] / structured["median_us"]
            rows.append(
                [
                    language,
                    structured_benchmark,
                    str(task_count),
                    f"{speedup:.2f}x",
                ]
            )
    print()
    print_table(
        "Within-language structured speedups",
        ["language", "benchmark", "task_count", "speedup_vs_sequential_baseline"],
        rows,
    )


BENCHMARK_PAIRS = [
    ("sequential_baseline", "sequential_baseline", "Sequential Baseline"),
    ("structured_thread_scope", "structured_task_group", "Structured Concurrency (CPU)"),
    ("spawn_overhead", "spawn_overhead", "Spawn Overhead (empty tasks)"),
]


def print_cross_language_comparison(summary: dict[tuple[str, str, int], dict]) -> None:
    cangjie_keys = {key for key in summary if key[0] == "cangjie"}
    swift_keys = {key for key in summary if key[0] == "swift"}

    if not cangjie_keys or not swift_keys:
        print()
        print("Cross-language median comparison")
        print("Need both Cangjie and Swift benchmark files to compare runtimes.")
        return

    for cj_name, sw_name, label in BENCHMARK_PAIRS:
        cj_data = {
            key[2]: value
            for key, value in summary.items()
            if key[0] == "cangjie" and key[1] == cj_name
        }
        sw_data = {
            key[2]: value
            for key, value in summary.items()
            if key[0] == "swift" and key[1] == sw_name
        }

        common_task_counts = sorted(set(cj_data) & set(sw_data))
        if not common_task_counts:
            continue

        rows: list[list[str]] = []
        for task_count in common_task_counts:
            cj = cj_data[task_count]
            sw = sw_data[task_count]
            if cj["median_us"] > 0 and sw["median_us"] > 0:
                ratio = sw["median_us"] / cj["median_us"]
                delta_pct = (cj["median_us"] - sw["median_us"]) / sw["median_us"] * 100
                if abs(delta_pct) < 3:
                    winner = "tied"
                elif delta_pct < 0:
                    winner = f"CJ {abs(delta_pct):.1f}% faster"
                else:
                    winner = f"Swift {delta_pct:.1f}% faster"
            else:
                ratio = 0
                winner = "n/a"
            rows.append(
                [
                    str(task_count),
                    f"{cj['median_us']}us",
                    f"{sw['median_us']}us",
                    f"{ratio:.2f}x" if ratio else "n/a",
                    winner,
                ]
            )
        print()
        print_table(
            f"Cross-language: {label} (cangjie={cj_name}, swift={sw_name})",
            ["task_count", "cangjie_median", "swift_median", "ratio", "winner"],
            rows,
        )


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(
            "Usage: python3 tools/compare_benchmarks.py <benchmark.csv> [<benchmark.csv> ...]",
            file=sys.stderr,
        )
        return 1

    rows: list[dict] = []
    for raw_path in argv[1:]:
        path = Path(raw_path)
        if not path.exists():
            print(f"Missing benchmark file: {path}", file=sys.stderr)
            return 1
        rows.extend(load_rows(path))

    if not rows:
        print("No benchmark rows found.", file=sys.stderr)
        return 1

    summary = summarize(rows)
    print_language_breakdown(summary)
    print_within_language_speedups(summary)
    print_cross_language_comparison(summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

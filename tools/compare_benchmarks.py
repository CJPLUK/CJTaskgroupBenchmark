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


def summarize(rows: list[dict]) -> dict[tuple[str, str, int], dict]:
    grouped: dict[tuple[str, str, int], list[int]] = defaultdict(list)
    for row in rows:
        key = (row["language"], row["benchmark"], row["task_count"])
        grouped[key].append(row["elapsed_us"])

    summary: dict[tuple[str, str, int], dict] = {}
    for key, samples in grouped.items():
        summary[key] = {
            "count": len(samples),
            "average_us": int(sum(samples) / len(samples)),
            "median_us": int(statistics.median(samples)),
            "min_us": min(samples),
            "max_us": max(samples),
        }
    return summary


def print_language_breakdown(summary: dict[tuple[str, str, int], dict]) -> None:
    print("Per-language benchmark summary")
    for key in sorted(summary):
        language, benchmark, task_count = key
        metrics = summary[key]
        print(
            f"- {language:8s} {benchmark:24s} task_count={task_count:2d} "
            f"median={metrics['median_us']:8d}us avg={metrics['average_us']:8d}us "
            f"min={metrics['min_us']:8d}us max={metrics['max_us']:8d}us"
        )


def print_within_language_speedups(summary: dict[tuple[str, str, int], dict]) -> None:
    print("\nWithin-language structured speedups")
    languages = sorted({key[0] for key in summary})
    for language in languages:
        sequential_key = "sequential_baseline"
        baseline = summary.get((language, sequential_key, 1))
        if baseline is None:
            continue
        structured_candidates = [
            key for key in summary if key[0] == language and key[1] != sequential_key
        ]
        for candidate in sorted(structured_candidates, key=lambda item: (item[1], item[2])):
            structured_benchmark = candidate[1]
            task_count = candidate[2]
            structured = summary[candidate]
            speedup = baseline["median_us"] / structured["median_us"]
            print(
                f"- {language:8s} {structured_benchmark:24s} task_count={task_count:2d} "
                f"speedup_vs_sequential_baseline={speedup:6.2f}x"
            )


def print_cross_language_comparison(summary: dict[tuple[str, str, int], dict]) -> None:
    print("\nCross-language median comparison")
    cangjie_candidates = {
        key[2]: value
        for key, value in summary.items()
        if key[0] == "cangjie" and key[1] != "sequential_baseline"
    }
    swift_candidates = {
        key[2]: value
        for key, value in summary.items()
        if key[0] == "swift" and key[1] != "sequential_baseline"
    }

    common_task_counts = sorted(set(cangjie_candidates) & set(swift_candidates))
    if not common_task_counts:
        print("- Need both Cangjie and Swift structured benchmark files to compare runtimes.")
        return

    for task_count in common_task_counts:
        cangjie = cangjie_candidates[task_count]
        swift = swift_candidates[task_count]
        ratio = cangjie["median_us"] / swift["median_us"]
        print(
            f"- task_count={task_count:2d} "
            f"cangjie_median={cangjie['median_us']:8d}us "
            f"swift_median={swift['median_us']:8d}us "
            f"cangjie_over_swift={ratio:6.2f}x"
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

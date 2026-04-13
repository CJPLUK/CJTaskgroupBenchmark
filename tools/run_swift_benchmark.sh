#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
results_dir="$repo_root/results"

mkdir -p "$results_dir"

(
  cd "$repo_root/swift-benchmark"
  swift run -c release >"$results_dir/swift-structured-benchmark.csv"
)

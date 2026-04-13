#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
results_dir="$repo_root/results"

mkdir -p "$results_dir"

(
  cd "$repo_root"
  cjpm run >"$results_dir/cangjie-structured-benchmark.csv"
)

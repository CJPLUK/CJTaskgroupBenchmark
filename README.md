# CJTaskgroupBenchmark

Benchmark workspace for comparing `cj_taskgroups` against Swift structured concurrency.

## Layout

```text
.
|- results/
|- src/
|- swift-benchmark/
`- tools/
```

## Run The Cangjie Benchmark

This submodule expects to live under the main `cj_taskgroups` repository, so the
benchmark executable depends on the parent library through a relative path.

```powershell
. ./path/to/cangjie/build-tools/envsetup.ps1
cjpm run
```

To mirror the main-repo CI gate, run:

```powershell
bash tools/run_cangjie_benchmark.sh
```

## Run The Swift Benchmark

```powershell
cd swift-benchmark
swift run
```

Or use the helper script:

```powershell
bash tools/run_swift_benchmark.sh
```

## Compare CSV Results

```powershell
python tools/compare_benchmarks.py results/cangjie-structured-benchmark.csv results/swift-structured-benchmark.csv
```

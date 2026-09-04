# CJTaskgroupBenchmark

Benchmark workspace for comparing Cangjie's `threadScope` against the raw
`spawn`/`Future.get()` primitive. A matching Swift structured-concurrency suite
is retained as a separate cross-language reference.

The Cangjie suite compares both APIs across:

- fixed-work CPU scaling;
- trivial-task scheduling cost;
- a skewed pipeline that highlights completion-order result processing; and
- mixed service-style latency with downstream CPU work.

The CPU and scheduling cases are direct overhead comparisons. The pipeline and
mixed-latency cases also show the difference between `threadScope`'s
completion-order iterator and collecting spawned futures in submission order.

## Layout

```text
.
|- minimal-benchmark/
|- results/
|- src/
|- swift-benchmark/
`- tools/
```

## Run The Minimal Cangjie Comparison

The standalone minimal suite contains only a fixed-total CPU comparison and a
trivial-task scheduling comparison. It alternates measurement order between
`threadScope` and `spawn` to reduce ordering bias.

```powershell
cd minimal-benchmark
cjpm run
```

Or write its CSV output to `results/cangjie-minimal-benchmark.csv`:

```powershell
bash tools/run_minimal_cangjie_benchmark.sh
```

Summarize the result with:

```powershell
python tools/compare_benchmarks.py results/cangjie-minimal-benchmark.csv
```

See [benchmark-results.ipynb](benchmark-results.ipynb) for a dependency-free
presentation and analysis of the recorded minimal benchmark results.

## Run The Cangjie Benchmark

The benchmark requires a Cangjie 1.1 toolchain with `std.concurrent` available.

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

The report includes a dedicated within-Cangjie `threadScope` versus `spawn`
comparison and keeps the Swift comparison separate.

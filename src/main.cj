package cj_taskgroup_benchmark

import std.concurrent.*
import std.collection.ArrayList
import std.time.DateTime
import std.math.sqrt

let benchmarkTotalWorkload: Int64 = 40000000
let benchmarkWarmupRuns: Int64 = 5
let benchmarkMeasuredRuns: Int64 = 15
let benchmarkCooldownMs: Int64 = 500
let benchmarkTrimCount: Int64 = 2

func buildBenchmarkTaskCounts(): ArrayList<Int64> {
    let counts = ArrayList<Int64>()
    counts.add(1)
    counts.add(2)
    counts.add(4)
    counts.add(8)
    counts.add(16)
    counts.add(32)
    counts.add(64)
    return counts
}

func chunkIterationsForTask(totalWorkload: Int64, taskCount: Int64, taskIndex: Int64): Int64 {
    let baseIterations = totalWorkload / taskCount
    let remainder = totalWorkload % taskCount
    if (taskIndex < remainder) {
        return baseIterations + 1
    }
    return baseIterations
}

func runCpuChunk(iterations: Int64, taskIndex: Int64): Int64 {
    var state = 1234567 + (taskIndex * 16)
    var remaining = iterations
    while (remaining > 0) {
        state = ((state * 1103515245) + 12345 + taskIndex) % 2147483647
        remaining -= 1
    }
    return state
}

func runSequentialCpuBenchmark(): Int64 {
    return runCpuChunk(benchmarkTotalWorkload, 0)
}

func runStructuredCpuBenchmark(taskCount: Int64): Int64 {
    return threadScope<Int64, Int64> {
        group =>
            var taskIndex = 0
            while (taskIndex < taskCount) {
                let currentTaskIndex = taskIndex
                let iterations = chunkIterationsForTask(benchmarkTotalWorkload, taskCount, currentTaskIndex)
                group.launch {
                    runCpuChunk(iterations, currentTaskIndex)
                }
                taskIndex += 1
            }

            var checksum = 0
            for (value in group) {
                checksum = (checksum + value) % 2147483647
            }
            checksum
    }
}

// Pipeline benchmark: one heavy task, many light tasks, each result triggers
// a small downstream serial computation.
//
// With submission-order iteration, the iterator blocks on task[0] (the heavy
// one) before any downstream work can start, so downstream work runs entirely
// AFTER the heavy task finishes.
//
// With completion-order iteration, the many light tasks stream in first, and
// their downstream work runs in parallel with the heavy task. Total wall
// clock is dominated by max(heavy_task, light_tasks + their_downstreams).
//
// Workloads are chosen so heavy >> N * downstream even at large task counts,
// which keeps the benefit visible across the whole task_count series.
let pipelineHeavyWorkload: Int64 = 30000000
let pipelineLightWorkload: Int64 = 500000
let pipelineDownstreamWorkload: Int64 = 500000

func runPipelineSkewed(taskCount: Int64): Int64 {
    return threadScope<Int64, Int64> {
        group =>
            var i: Int64 = 0
            while (i < taskCount) {
                let currentTaskIndex = i
                let workload = if (currentTaskIndex == 0) {
                    pipelineHeavyWorkload
                } else {
                    pipelineLightWorkload
                }
                group.launch {
                    runCpuChunk(workload, currentTaskIndex)
                }
                i += 1
            }

            // Serial downstream processing per result. The iterator order
            // (submission vs completion) determines whether this loop can
            // begin overlapping with the heavy task or has to wait for it.
            var checksum: Int64 = 0
            for (value in group) {
                let downstream = runCpuChunk(pipelineDownstreamWorkload, value % 16)
                checksum = (checksum + downstream) % 2147483647
            }
            checksum
    }
}

// Mixed-latency benchmark: each task sleeps for a duration drawn from a
// heavy-tailed pseudo-random distribution (80% fast / 15% medium / 5% slow),
// modelling realistic service latency. Each result triggers a small CPU
// downstream step.
//
// Unlike pipeline_skewed (where the slow task is always task[0] -- the
// worst case for submission-order iteration), here the slow tasks are
// scattered randomly across positions. This is a more realistic workload
// and shows the *typical* completion-order benefit on heterogeneous
// task durations, rather than the pathological max.
//
// Latencies are deterministic per task index so runs are reproducible.
//
// NOTE on bucket sizing: all buckets sit at >= 10 ms because Cangjie's
// current sleep() has a ~10 ms minimum granularity (verified separately on
// macOS arm64). Using sub-ms sleeps would silently round up and distort the
// distribution. Sub-ms latencies (cache hits etc.) are not modelled here;
// they belong in a CPU-bound benchmark, not a sleep-based one.
let mixedLatencyDownstreamWorkload: Int64 = 1500000  // ~4-5 ms per-result CPU step

// Returns the sleep duration in microseconds for this task index.
// Distribution:
//   80% fast (10-28 ms)  ~ same-AZ RPC, cached DB query
//   15% medium (50-100 ms) ~ cross-AZ DB, slow RPC
//    5% slow (150-250 ms)  ~ cold storage, far-region request
// Mixing function is a simple Knuth multiplicative hash -- deterministic but
// spreads slow tasks across positions so neither submission-order nor
// completion-order can game the ordering.
func mixedLatencyMicros(taskIndex: Int64): Int64 {
    let mixed = ((taskIndex + 1) * 2654435761) % 1000
    let r = if (mixed < 0) { mixed + 1000 } else { mixed }

    if (r < 800) {
        // 80%: fast (10, 13, 16, 19, 22, 25, 28 ms)
        return 10000 + (r % 7) * 3000
    } else if (r < 950) {
        // 15%: medium (50, 60, 70, 80, 90, 100 ms)
        return 50000 + (r % 6) * 10000
    } else {
        // 5%: slow tail (150, 175, 200, 225, 250 ms)
        return 150000 + (r % 5) * 25000
    }
}

func runMixedLatency(taskCount: Int64): Int64 {
    return threadScope<Int64, Int64> {
        group =>
            var i: Int64 = 0
            while (i < taskCount) {
                let currentTaskIndex = i
                let latencyUs = mixedLatencyMicros(currentTaskIndex)
                group.launch {
                    sleep(Duration.microsecond * latencyUs)
                    latencyUs
                }
                i += 1
            }

            var checksum: Int64 = 0
            for (value in group) {
                let downstream = runCpuChunk(mixedLatencyDownstreamWorkload, value % 16)
                checksum = (checksum + downstream) % 2147483647
            }
            checksum
    }
}

// Scheduling-cost benchmark: measures pure scheduling overhead (spawn,
// queue, atomic, iterator) across a wide range of task counts using
// trivial tasks (each returns its index, no CPU work).
//
// task_count series spans 5 orders of magnitude: 1, 8, 64, 1k, 10k, 100k.
// inner_reps is chosen per task_count so that each measurement covers
// ~10,000 total spawn/join operations -- enough wall-clock to make
// DateTime.now() jitter negligible without bloating run time at large N.
//
// The CSV's total_workload column records reps * task_count (i.e. total
// tasks executed in that measurement), so per-task cost can be computed
// as elapsed_us / total_workload.
//
// (Captures the loop counter to defeat dead-code elimination -- each
// task returns a distinct, non-constant value so the compiler can't
// fold the sum to 0 and elide the spawn.)
let schedulingCostTargetTasks: Int64 = 10000

func buildSchedulingCostTaskCounts(): ArrayList<Int64> {
    let counts = ArrayList<Int64>()
    counts.add(1)
    counts.add(8)
    counts.add(64)
    counts.add(1000)
    counts.add(10000)
    counts.add(100000)
    return counts
}

func schedulingCostInnerReps(taskCount: Int64): Int64 {
    let reps = schedulingCostTargetTasks / taskCount
    if (reps < 1) { return 1 }
    return reps
}

func runSchedulingCost(taskCount: Int64): Int64 {
    let reps = schedulingCostInnerReps(taskCount)
    var result: Int64 = 0
    var rep: Int64 = 0
    while (rep < reps) {
        result = threadScope<Int64, Int64> {
            group =>
                var i: Int64 = 0
                while (i < taskCount) {
                    let currentTaskIndex = i
                    group.launch { currentTaskIndex }
                    i += 1
                }
                var sum: Int64 = 0
                for (value in group) {
                    sum += value
                }
                sum
        }
        rep += 1
    }
    return result
}

func averageMicros(samples: ArrayList<Int64>): Int64 {
    var total: Int64 = 0
    for (sample in samples) {
        total += sample
    }
    return total / samples.size
}

func stddevMicros(samples: ArrayList<Int64>, avg: Int64): Int64 {
    var sumSq: Float64 = 0.0
    for (sample in samples) {
        let diff = Float64(sample - avg)
        sumSq += diff * diff
    }
    return Int64(sqrt(sumSq / Float64(samples.size)))
}

func sortAscending(values: ArrayList<Int64>): ArrayList<Int64> {
    let sorted = ArrayList<Int64>(values)
    var index = 1
    while (index < sorted.size) {
        let current = sorted[index]
        var insertAt = index - 1

        while (insertAt >= 0 && sorted[insertAt] > current) {
            sorted[insertAt + 1] = sorted[insertAt]
            insertAt -= 1
        }

        sorted[insertAt + 1] = current
        index += 1
    }
    return sorted
}

func medianMicros(samples: ArrayList<Int64>): Int64 {
    let sorted = sortAscending(samples)
    let middle = sorted.size / 2
    if ((sorted.size % 2) == 0) {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}

func minMicros(samples: ArrayList<Int64>): Int64 {
    if (samples.size == 0) { return 0 }
    var m = samples[0]
    for (s in samples) {
        if (s < m) { m = s }
    }
    return m
}

func maxMicros(samples: ArrayList<Int64>): Int64 {
    if (samples.size == 0) { return 0 }
    var m = samples[0]
    for (s in samples) {
        if (s > m) { m = s }
    }
    return m
}

func measureBenchmark(benchmarkName: String, workload: Int64, taskCount: Int64, iteration: Int64, run: () -> Int64): Int64 {
    let start = DateTime.now()
    let checksum = run()
    let elapsedMicros = (DateTime.now() - start).toMicroseconds()
    println("cangjie,${benchmarkName},${workload},${taskCount},${iteration},${elapsedMicros},${checksum}")
    return elapsedMicros
}

func runSingleCase(benchmarkName: String, workload: Int64, taskCount: Int64, run: () -> Int64) {
    sleep(Duration.millisecond * benchmarkCooldownMs)

    var warmupIndex = 0
    while (warmupIndex < benchmarkWarmupRuns) {
        run()
        warmupIndex += 1
    }

    let samples = ArrayList<Int64>()
    for (iteration in 1..=benchmarkMeasuredRuns) {
        let elapsedMicros = measureBenchmark(benchmarkName, workload, taskCount, iteration) {
            run()
        }
        samples.add(elapsedMicros)
    }

    let sorted = sortAscending(samples)
    // Only trim if we have strictly more samples than 2 * trim_count.
    // Otherwise trimming would produce a degenerate (possibly empty) set
    // and the downstream stats would be meaningless or crash.
    let trimmed = ArrayList<Int64>()
    if (sorted.size > 2 * benchmarkTrimCount) {
        var ti: Int64 = benchmarkTrimCount
        while (ti < sorted.size - benchmarkTrimCount) {
            trimmed.add(sorted[ti])
            ti += 1
        }
    } else {
        for (s in sorted) {
            trimmed.add(s)
        }
    }

    let avg = averageMicros(trimmed)
    let med = medianMicros(trimmed)
    let sd = stddevMicros(trimmed, avg)
    let mn = minMicros(trimmed)
    let mx = maxMicros(trimmed)
    println("# summary,cangjie,${benchmarkName},task_count=${taskCount},avg_us=${avg},median_us=${med},stddev_us=${sd},min_us=${mn},max_us=${mx}")
}

func runSeries(benchmarkName: String, workload: Int64, run: (Int64) -> Int64) {
    for (taskCount in buildBenchmarkTaskCounts()) {
        runSingleCase(benchmarkName, workload, taskCount) {
            run(taskCount)
        }
    }
}

main(): Int64 {
    println("# Structured concurrency CPU benchmark (Cangjie)")
    println("# total_workload=${benchmarkTotalWorkload},warmup_runs=${benchmarkWarmupRuns},measured_runs=${benchmarkMeasuredRuns},cooldown_ms=${benchmarkCooldownMs},scheduling_cost_target_tasks=${schedulingCostTargetTasks}")
    println("language,benchmark,total_workload,task_count,iteration,elapsed_us,checksum")

    // CPU benchmarks: total_workload reflects the actual amount of work done.
    runSingleCase("sequential_baseline", benchmarkTotalWorkload, 1) {
        runSequentialCpuBenchmark()
    }
    runSeries("structured_thread_scope", benchmarkTotalWorkload, { taskCount =>
        runStructuredCpuBenchmark(taskCount)
    })
    // pipeline_skewed: 1 heavy + (N-1) light tasks, each result triggers a
    // small serial downstream step. Demonstrates completion-order benefit.
    let pipelineWorkload = pipelineHeavyWorkload + pipelineLightWorkload * 7
    runSeries("pipeline_skewed", pipelineWorkload, { taskCount =>
        runPipelineSkewed(taskCount)
    })
    // mixed_latency: heavy-tailed sleep latency distribution. workload=0
    // because no real CPU work; the timing is dominated by sleep().
    runSeries("mixed_latency", 0, { taskCount =>
        runMixedLatency(taskCount)
    })
    // scheduling_cost: pure spawn/iterate overhead across 5 orders of N.
    // Adaptive inner_reps targets ~10k total tasks per measurement;
    // workload column records the actual total (reps * task_count).
    for (taskCount in buildSchedulingCostTaskCounts()) {
        let reps = schedulingCostInnerReps(taskCount)
        let workload = reps * taskCount
        runSingleCase("scheduling_cost", workload, taskCount) {
            runSchedulingCost(taskCount)
        }
    }
    return 0
}

package cj_taskgroup_benchmark

import cj_taskgroups.*
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
    return ThreadScope<Int64, Int64> {
        group =>
            var taskIndex = 0
            while (taskIndex < taskCount) {
                let currentTaskIndex = taskIndex
                let iterations = chunkIterationsForTask(benchmarkTotalWorkload, taskCount, currentTaskIndex)
                group.add {
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

let spawnOverheadRepeat: Int64 = 1000

func runSpawnOverhead(taskCount: Int64): Int64 {
    var result: Int64 = 0
    var rep: Int64 = 0
    while (rep < spawnOverheadRepeat) {
        result = ThreadScope<Int64, Int64> {
            group =>
                var i: Int64 = 0
                while (i < taskCount) {
                    // Capture the loop counter so each task returns a distinct
                    // non-constant value; otherwise the compiler may fold the
                    // sum to 0 and elide the spawn entirely (DCE), giving a
                    // misleadingly tiny benchmark result.
                    let currentTaskIndex = i
                    group.add { currentTaskIndex }
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
    println("# total_workload=${benchmarkTotalWorkload},warmup_runs=${benchmarkWarmupRuns},measured_runs=${benchmarkMeasuredRuns},cooldown_ms=${benchmarkCooldownMs},spawn_overhead_repeat=${spawnOverheadRepeat}")
    println("language,benchmark,total_workload,task_count,iteration,elapsed_us,checksum")

    // CPU benchmarks: total_workload reflects the actual amount of work done.
    runSingleCase("sequential_baseline", benchmarkTotalWorkload, 1) {
        runSequentialCpuBenchmark()
    }
    runSeries("structured_thread_scope", benchmarkTotalWorkload, { taskCount =>
        runStructuredCpuBenchmark(taskCount)
    })
    // spawn_overhead does no CPU work; report total_workload=0 to avoid
    // misleading downstream analyses that scale by workload.
    runSeries("spawn_overhead", 0, { taskCount =>
        runSpawnOverhead(taskCount)
    })
    return 0
}

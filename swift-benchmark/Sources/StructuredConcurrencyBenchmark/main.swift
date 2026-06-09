import Dispatch
import Foundation

private let benchmarkTotalWorkload = 40_000_000
private let benchmarkWarmupRuns = 5
private let benchmarkMeasuredRuns = 15
private let benchmarkCooldownMs: UInt32 = 500
private let benchmarkTrimCount = 2

private func buildTaskCounts() -> [Int] {
    [1, 2, 4, 8, 16, 32, 64]
}

private func chunkIterations(totalWorkload: Int, taskCount: Int, taskIndex: Int) -> Int {
    let baseIterations = totalWorkload / taskCount
    let remainder = totalWorkload % taskCount
    return baseIterations + (taskIndex < remainder ? 1 : 0)
}

private func runCPUChunk(iterations: Int, taskIndex: Int) -> Int64 {
    var state: Int64 = 1_234_567 + Int64(taskIndex * 16)
    for _ in 0 ..< iterations {
        state = ((state * 1_103_515_245) + 12_345 + Int64(taskIndex)) % 2_147_483_647
    }
    return state
}

private func runSequentialBaseline() -> Int64 {
    runCPUChunk(iterations: benchmarkTotalWorkload, taskIndex: 0)
}

private func runStructured(taskCount: Int) async -> Int64 {
    await withTaskGroup(of: Int64.self, returning: Int64.self) { group in
        for taskIndex in 0 ..< taskCount {
            let currentTaskIndex = taskIndex
            let iterations = chunkIterations(
                totalWorkload: benchmarkTotalWorkload,
                taskCount: taskCount,
                taskIndex: currentTaskIndex
            )
            group.addTask {
                runCPUChunk(iterations: iterations, taskIndex: currentTaskIndex)
            }
        }

        var checksum: Int64 = 0
        for await value in group {
            checksum = (checksum + value) % 2_147_483_647
        }
        return checksum
    }
}

// Pipeline benchmark: one heavy task, many light tasks, each result triggers
// a small downstream serial computation. Swift's TaskGroup is always
// completion-order, so this is the "baseline" that Cangjie's iteration-order
// branch is trying to match.
private let pipelineHeavyWorkload = 30_000_000
private let pipelineLightWorkload = 500_000
private let pipelineDownstreamWorkload = 500_000

private func runPipelineSkewed(taskCount: Int) async -> Int64 {
    var checksum: Int64 = 0

    await withTaskGroup(of: Int64.self) { group in
        for taskIndex in 0 ..< taskCount {
            let currentTaskIndex = taskIndex
            let workload = currentTaskIndex == 0
                ? pipelineHeavyWorkload
                : pipelineLightWorkload
            group.addTask {
                runCPUChunk(iterations: workload, taskIndex: currentTaskIndex)
            }
        }

        for await value in group {
            let downstream = runCPUChunk(
                iterations: pipelineDownstreamWorkload,
                taskIndex: Int(value % 16)
            )
            checksum = (checksum + downstream) % 2_147_483_647
        }
    }

    return checksum
}

// Mixed-latency benchmark: each task sleeps for a duration drawn from a
// heavy-tailed pseudo-random distribution (80% fast / 15% medium / 5% slow),
// modelling realistic service latency. Each result triggers a small CPU
// downstream step. Sleep durations are deterministic per task index.
//
// All buckets are >= 10 ms to match Cangjie's sleep granularity, so the
// distributions on both sides exercise the same sleep regime.
//
// Swift's TaskGroup is always completion-order, so this is the "baseline"
// that Cangjie's iteration-order implementation is being measured against.
private let mixedLatencyDownstreamWorkload = 1_500_000  // ~4-5 ms per-result CPU step

private func mixedLatencyMicros(taskIndex: Int) -> Int {
    let mixed = ((taskIndex + 1) &* 2_654_435_761) % 1000
    let r = mixed < 0 ? mixed + 1000 : mixed

    if r < 800 {
        // 80% fast (10-28 ms)
        return 10_000 + (r % 7) * 3_000
    } else if r < 950 {
        // 15% medium (50-100 ms)
        return 50_000 + (r % 6) * 10_000
    } else {
        // 5% slow tail (150-250 ms)
        return 150_000 + (r % 5) * 25_000
    }
}

private func runMixedLatency(taskCount: Int) async -> Int64 {
    var checksum: Int64 = 0

    await withTaskGroup(of: Int64.self) { group in
        for taskIndex in 0 ..< taskCount {
            let currentTaskIndex = taskIndex
            let latencyUs = mixedLatencyMicros(taskIndex: currentTaskIndex)
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(latencyUs) * 1_000)
                return Int64(latencyUs)
            }
        }

        for await value in group {
            let downstream = runCPUChunk(
                iterations: mixedLatencyDownstreamWorkload,
                taskIndex: Int(value % 16)
            )
            checksum = (checksum + downstream) % 2_147_483_647
        }
    }

    return checksum
}

// Scheduling-cost benchmark: pure spawn/iterate overhead across 5 orders
// of N (1, 8, 64, 1k, 10k, 100k). Adaptive inner_reps so each measurement
// covers ~10k total spawn/join operations.
private let schedulingCostTargetTasks = 10_000

private func buildSchedulingCostTaskCounts() -> [Int] {
    [1, 8, 64, 1_000, 10_000, 100_000]
}

private func schedulingCostInnerReps(_ taskCount: Int) -> Int {
    max(1, schedulingCostTargetTasks / taskCount)
}

private func runSchedulingCost(taskCount: Int) async -> Int64 {
    let reps = schedulingCostInnerReps(taskCount)
    var result: Int64 = 0
    for _ in 0 ..< reps {
        result = await withTaskGroup(of: Int64.self, returning: Int64.self) { group in
            for taskIndex in 0 ..< taskCount {
                let currentTaskIndex = taskIndex
                group.addTask { Int64(currentTaskIndex) }
            }
            var sum: Int64 = 0
            for await value in group {
                sum += value
            }
            return sum
        }
    }
    return result
}

private func averageMicros(_ samples: [Int64]) -> Int64 {
    samples.reduce(0, +) / Int64(samples.count)
}

private func stddevMicros(_ samples: [Int64], avg: Int64) -> Int64 {
    let sumSq = samples.reduce(0.0) { acc, s in
        let diff = Double(s - avg)
        return acc + diff * diff
    }
    return Int64(Foundation.sqrt(sumSq / Double(samples.count)))
}

private func medianMicros(_ samples: [Int64]) -> Int64 {
    let sorted = samples.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}

private func measureBenchmark(
    benchmarkName: String,
    workload: Int,
    taskCount: Int,
    iteration: Int,
    run: @Sendable () async -> Int64
) async -> Int64 {
    let start = DispatchTime.now().uptimeNanoseconds
    let checksum = await run()
    let end = DispatchTime.now().uptimeNanoseconds
    let elapsedMicros = Int64((end - start) / 1_000)

    print("swift,\(benchmarkName),\(workload),\(taskCount),\(iteration),\(elapsedMicros),\(checksum)")
    return elapsedMicros
}

private func runSingleCase(
    benchmarkName: String,
    workload: Int,
    taskCount: Int,
    run: @Sendable @escaping () async -> Int64
) async {
    usleep(benchmarkCooldownMs * 1_000)

    for _ in 0 ..< benchmarkWarmupRuns {
        _ = await run()
    }

    var samples: [Int64] = []
    for iteration in 1 ... benchmarkMeasuredRuns {
        let elapsedMicros = await measureBenchmark(
            benchmarkName: benchmarkName,
            workload: workload,
            taskCount: taskCount,
            iteration: iteration
        ) {
            await run()
        }
        samples.append(elapsedMicros)
    }

    let sorted = samples.sorted()
    // Only trim if we have strictly more samples than 2 * trim_count.
    // Otherwise fall back to using all samples; trimming a too-small set
    // would produce degenerate (possibly empty) statistics.
    let trimmed: [Int64]
    if sorted.count > 2 * benchmarkTrimCount {
        trimmed = Array(sorted[benchmarkTrimCount ..< (sorted.count - benchmarkTrimCount)])
    } else {
        trimmed = sorted
    }

    let avg = averageMicros(trimmed)
    let med = medianMicros(trimmed)
    let sd = stddevMicros(trimmed, avg: avg)
    let mn = trimmed.min() ?? 0
    let mx = trimmed.max() ?? 0
    print("# summary,swift,\(benchmarkName),task_count=\(taskCount),avg_us=\(avg),median_us=\(med),stddev_us=\(sd),min_us=\(mn),max_us=\(mx)")
}

private func runSeries(
    benchmarkName: String,
    workload: Int,
    run: @Sendable @escaping (Int) async -> Int64
) async {
    for taskCount in buildTaskCounts() {
        await runSingleCase(benchmarkName: benchmarkName, workload: workload, taskCount: taskCount) {
            await run(taskCount)
        }
    }
}

@main
struct StructuredConcurrencyBenchmarkCLI {
    static func main() async {
        print("# Structured concurrency CPU benchmark (Swift)")
        print("# total_workload=\(benchmarkTotalWorkload),warmup_runs=\(benchmarkWarmupRuns),measured_runs=\(benchmarkMeasuredRuns),cooldown_ms=\(benchmarkCooldownMs),scheduling_cost_target_tasks=\(schedulingCostTargetTasks)")
        print("language,benchmark,total_workload,task_count,iteration,elapsed_us,checksum")

        // CPU benchmarks: workload reflects the actual amount of work done.
        await runSingleCase(benchmarkName: "sequential_baseline", workload: benchmarkTotalWorkload, taskCount: 1) {
            runSequentialBaseline()
        }
        await runSeries(benchmarkName: "structured_task_group", workload: benchmarkTotalWorkload) { taskCount in
            await runStructured(taskCount: taskCount)
        }
        // pipeline_skewed: 1 heavy + (N-1) light tasks, each result triggers a
        // small serial downstream step. Demonstrates completion-order benefit.
        let pipelineWorkload = pipelineHeavyWorkload + pipelineLightWorkload * 7
        await runSeries(benchmarkName: "pipeline_skewed", workload: pipelineWorkload) { taskCount in
            await runPipelineSkewed(taskCount: taskCount)
        }
        // mixed_latency: heavy-tailed sleep latency. workload=0 (no CPU work).
        await runSeries(benchmarkName: "mixed_latency", workload: 0) { taskCount in
            await runMixedLatency(taskCount: taskCount)
        }
        // scheduling_cost: pure spawn/iterate overhead across 5 orders of N.
        // Adaptive inner_reps; workload = reps * task_count (total tasks).
        for taskCount in buildSchedulingCostTaskCounts() {
            let reps = schedulingCostInnerReps(taskCount)
            let workload = reps * taskCount
            await runSingleCase(benchmarkName: "scheduling_cost", workload: workload, taskCount: taskCount) {
                await runSchedulingCost(taskCount: taskCount)
            }
        }
    }
}

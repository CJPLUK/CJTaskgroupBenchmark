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

private func runSpawnOverhead(taskCount: Int) async -> Int64 {
    await withTaskGroup(of: Int64.self, returning: Int64.self) { group in
        for _ in 0 ..< taskCount {
            group.addTask { 0 }
        }
        var sum: Int64 = 0
        for await value in group {
            sum += value
        }
        return sum
    }
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
    taskCount: Int,
    iteration: Int,
    run: @Sendable () async -> Int64
) async -> Int64 {
    let start = DispatchTime.now().uptimeNanoseconds
    let checksum = await run()
    let end = DispatchTime.now().uptimeNanoseconds
    let elapsedMicros = Int64((end - start) / 1_000)

    print("swift,\(benchmarkName),\(benchmarkTotalWorkload),\(taskCount),\(iteration),\(elapsedMicros),\(checksum)")
    return elapsedMicros
}

private func runSingleCase(
    benchmarkName: String,
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
            taskCount: taskCount,
            iteration: iteration
        ) {
            await run()
        }
        samples.append(elapsedMicros)
    }

    let sorted = samples.sorted()
    let trimmed = Array(sorted[benchmarkTrimCount ..< (sorted.count - benchmarkTrimCount)])

    let avg = averageMicros(trimmed)
    let med = medianMicros(trimmed)
    let sd = stddevMicros(trimmed, avg: avg)
    let mn = trimmed.min()!
    let mx = trimmed.max()!
    print("# summary,swift,\(benchmarkName),task_count=\(taskCount),avg_us=\(avg),median_us=\(med),stddev_us=\(sd),min_us=\(mn),max_us=\(mx)")
}

private func runSeries(
    benchmarkName: String,
    run: @Sendable @escaping (Int) async -> Int64
) async {
    for taskCount in buildTaskCounts() {
        await runSingleCase(benchmarkName: benchmarkName, taskCount: taskCount) {
            await run(taskCount)
        }
    }
}

@main
struct StructuredConcurrencyBenchmarkCLI {
    static func main() async {
        print("# Structured concurrency CPU benchmark (Swift)")
        print("# total_workload=\(benchmarkTotalWorkload),warmup_runs=\(benchmarkWarmupRuns),measured_runs=\(benchmarkMeasuredRuns),cooldown_ms=\(benchmarkCooldownMs)")
        print("language,benchmark,total_workload,task_count,iteration,elapsed_us,checksum")

        await runSingleCase(benchmarkName: "sequential_baseline", taskCount: 1) {
            runSequentialBaseline()
        }
        await runSeries(benchmarkName: "structured_task_group") { taskCount in
            await runStructured(taskCount: taskCount)
        }
        await runSeries(benchmarkName: "spawn_overhead") { taskCount in
            await runSpawnOverhead(taskCount: taskCount)
        }
    }
}

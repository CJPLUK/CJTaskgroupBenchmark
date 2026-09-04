package cj_taskgroup_minimal_benchmark

import std.concurrent.*
import std.collection.ArrayList
import std.time.*

let cpuTotalIterations: Int64 = 20000000
let schedulingTargetTasks: Int64 = 8192
let warmupRuns: Int64 = 3
let measuredRuns: Int64 = 15
let cooldownMs: Int64 = 100

func cpuTaskCounts(): ArrayList<Int64> {
    return ArrayList<Int64>([1, 2, 4, 8, 16, 32])
}

func schedulingTaskCounts(): ArrayList<Int64> {
    return ArrayList<Int64>([1, 8, 64, 1024, 8192])
}

func chunkIterations(taskCount: Int64, taskIndex: Int64): Int64 {
    let base = cpuTotalIterations / taskCount
    if (taskIndex < cpuTotalIterations % taskCount) {
        return base + 1
    }
    return base
}

// Deterministic integer work keeps the task alive and produces a checksum.
func cpuWork(iterations: Int64, taskIndex: Int64): Int64 {
    var state: Int64 = 1234567 + taskIndex * 16
    var remaining = iterations
    while (remaining > 0) {
        state = (state * 1103515245 + 12345 + taskIndex) % 2147483647
        remaining -= 1
    }
    return state
}

func runThreadScopeCpu(taskCount: Int64): Int64 {
    return threadScope<Int64, Int64> {
        group =>
            var taskIndex: Int64 = 0
            while (taskIndex < taskCount) {
                let currentTaskIndex = taskIndex
                let iterations = chunkIterations(taskCount, currentTaskIndex)
                group.launch { cpuWork(iterations, currentTaskIndex) }
                taskIndex += 1
            }

            var checksum: Int64 = 0
            for (value in group) {
                checksum = (checksum + value) % 2147483647
            }
            checksum
    }
}

func runSpawnCpu(taskCount: Int64): Int64 {
    let futures = ArrayList<Future<Int64>>()
    var taskIndex: Int64 = 0
    while (taskIndex < taskCount) {
        let currentTaskIndex = taskIndex
        let iterations = chunkIterations(taskCount, currentTaskIndex)
        futures.add(spawn { cpuWork(iterations, currentTaskIndex) })
        taskIndex += 1
    }

    var checksum: Int64 = 0
    for (future in futures) {
        checksum = (checksum + future.get()) % 2147483647
    }
    return checksum
}

func schedulingRepetitions(taskCount: Int64): Int64 {
    return schedulingTargetTasks / taskCount
}

func runThreadScopeScheduling(taskCount: Int64): Int64 {
    let repetitions = schedulingRepetitions(taskCount)
    var checksum: Int64 = 0
    var repetition: Int64 = 0
    while (repetition < repetitions) {
        checksum += threadScope<Int64, Int64> {
            group =>
                var taskIndex: Int64 = 0
                while (taskIndex < taskCount) {
                    let currentTaskIndex = taskIndex
                    group.launch { currentTaskIndex }
                    taskIndex += 1
                }

                var sum: Int64 = 0
                for (value in group) {
                    sum += value
                }
                sum
        }
        repetition += 1
    }
    return checksum
}

func runSpawnScheduling(taskCount: Int64): Int64 {
    let repetitions = schedulingRepetitions(taskCount)
    var checksum: Int64 = 0
    var repetition: Int64 = 0
    while (repetition < repetitions) {
        let futures = ArrayList<Future<Int64>>()
        var taskIndex: Int64 = 0
        while (taskIndex < taskCount) {
            let currentTaskIndex = taskIndex
            futures.add(spawn { currentTaskIndex })
            taskIndex += 1
        }

        for (future in futures) {
            checksum += future.get()
        }
        repetition += 1
    }
    return checksum
}

func measure(benchmark: String, workload: Int64, taskCount: Int64, iteration: Int64,
    run: () -> Int64): Unit {
    let start = MonoTime.now()
    let checksum = run()
    let elapsedMicros = (MonoTime.now() - start).toMicroseconds()
    println("cangjie,${benchmark},${workload},${taskCount},${iteration},${elapsedMicros},${checksum}")
}

// Alternate measurement order so neither implementation always receives the
// warmer CPU or the first scheduler placement.
func runPairedCase(threadScopeBenchmark: String, spawnBenchmark: String, workload: Int64,
    taskCount: Int64, threadScopeRun: () -> Int64, spawnRun: () -> Int64): Unit {
    sleep(Duration.millisecond * cooldownMs)
    var warmup: Int64 = 0
    while (warmup < warmupRuns) {
        threadScopeRun()
        spawnRun()
        warmup += 1
    }

    for (iteration in 1..=measuredRuns) {
        if ((iteration % 2) == 1) {
            measure(threadScopeBenchmark, workload, taskCount, iteration, threadScopeRun)
            measure(spawnBenchmark, workload, taskCount, iteration, spawnRun)
        } else {
            measure(spawnBenchmark, workload, taskCount, iteration, spawnRun)
            measure(threadScopeBenchmark, workload, taskCount, iteration, threadScopeRun)
        }
    }
}

main(): Int64 {
    println("# Minimal threadScope versus spawn benchmark")
    println("# warmup_runs=${warmupRuns},measured_runs=${measuredRuns},cooldown_ms=${cooldownMs}")
    println("language,benchmark,total_workload,task_count,iteration,elapsed_us,checksum")

    for (taskCount in cpuTaskCounts()) {
        runPairedCase("structured_thread_scope", "spawn_cpu", cpuTotalIterations, taskCount,
            { => runThreadScopeCpu(taskCount) },
            { => runSpawnCpu(taskCount) })
    }

    for (taskCount in schedulingTaskCounts()) {
        let workload = schedulingRepetitions(taskCount) * taskCount
        runPairedCase("scheduling_cost", "spawn_scheduling_cost", workload, taskCount,
            { => runThreadScopeScheduling(taskCount) },
            { => runSpawnScheduling(taskCount) })
    }
    return 0
}

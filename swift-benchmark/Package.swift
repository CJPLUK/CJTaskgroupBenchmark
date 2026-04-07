// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "StructuredConcurrencyBenchmark",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .executable(
            name: "structured-concurrency-benchmark",
            targets: ["StructuredConcurrencyBenchmark"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "StructuredConcurrencyBenchmark"
        ),
    ]
)

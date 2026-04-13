// swift-tools-version: 5.10

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

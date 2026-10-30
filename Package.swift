// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Plushboii",
    products: [.library(name: "TopologyKit", targets: ["TopologyKit"])],
    targets: [
        .target(name: "TopologyKit", path: "Plushboii", sources: ["Topology", "Print", "Ingestion/MeshSchema.swift"]),
        .testTarget(name: "TopologyEngineTests", dependencies: ["TopologyKit"], path: "Tests/TopologyEngineTests"),
    ]
)

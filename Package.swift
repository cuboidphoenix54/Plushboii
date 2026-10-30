// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Plushboii",
    platforms: [.macOS(.v14)],
    products: [.library(name: "TopologyKit", targets: ["TopologyKit"])],
    targets: [
        .target(name: "TopologyKit", path: "Plushboii", sources: ["Topology", "Print", "Ingestion/MeshSchema.swift", "Ingestion/STLReader.swift", "Ingestion/LocalLRMTensorParser.swift", "Ingestion/MarchingTetrahedra.swift"]),
        .testTarget(name: "TopologyEngineTests", dependencies: ["TopologyKit"], path: "Tests/TopologyEngineTests"),
    ]
)

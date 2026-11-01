// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Plushboii",
    platforms: [.macOS(.v14)],
    products: [.library(name: "TopologyKit", targets: ["TopologyKit"]), .executable(name: "plushagent", targets: ["plushagent"]), .executable(name: "plushdata", targets: ["plushdata"])],
    targets: [
        .target(name: "TopologyKit", path: "Plushboii", sources: ["Agent", "Topology", "Print", "Topology/SeamSuggestionEngine.swift", "Topology/OnDeviceSeamAdvisor.swift", "Ingestion/MeshSchema.swift", "Ingestion/STLReader.swift", "Ingestion/OBJMeshReader.swift", "Ingestion/LocalLRMTensorParser.swift", "Ingestion/MarchingTetrahedra.swift"]),
        .executableTarget(name: "plushagent", dependencies: ["TopologyKit"], path: "Sources/plushagent"),
        .executableTarget(name: "plushdata", dependencies: ["TopologyKit"], path: "Sources/plushdata"),
        .testTarget(name: "TopologyEngineTests", dependencies: ["TopologyKit"], path: "Tests/TopologyEngineTests"),
    ]
)

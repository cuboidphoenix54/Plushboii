import AppKit
import SceneKit
import simd

/// Standardized output of every ingestion path: a node for rendering plus the validated arrays for the math engine.
/// Vertex `i` of the node's geometry is `mesh.vertices[i]`, so seam picks on the node index straight into `mesh`.
typealias IngestedMesh = (node: SCNNode, mesh: ImportedMesh)

@MainActor
protocol MeshIngestionService: AnyObject {
    /// File extension of the format that was ingested, stored in `PatternPiece.sourceMeshFormat`.
    var sourceFormat: String { get }
    var suggestedName: String { get }
    /// Throws a typed error instead of ever returning partial or placeholder geometry.
    func ingest() async throws -> IngestedMesh
}

/// Runs blocking work (disk reads, parsing) on a background thread and forwards cancellation to it.
func offMainActor<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached(priority: .userInitiated) { try work() }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

/// Buffers for one mesh, built off the main actor. `SCNNode` is not `Sendable`, so only this value crosses
/// actors and `makeNode()` assembles the node on the main actor.
struct MeshRenderData: Sendable {
    let positions: Data
    let normals: Data
    let indices: Data
    let vertexCount: Int
    let triangleCount: Int

    init(_ mesh: ImportedMesh) {
        var positions = [Float](repeating: 0, count: mesh.vertices.count * 3)
        var accumulated = [SIMD3<Double>](repeating: .zero, count: mesh.vertices.count)
        for (i, v) in mesh.vertices.enumerated() {
            positions[i * 3] = Float(v.x)
            positions[i * 3 + 1] = Float(v.y)
            positions[i * 3 + 2] = Float(v.z)
        }
        var indices = [UInt32](repeating: 0, count: mesh.triangles.count * 3)
        for (t, tri) in mesh.triangles.enumerated() {
            indices[t * 3] = UInt32(tri.a)
            indices[t * 3 + 1] = UInt32(tri.b)
            indices[t * 3 + 2] = UInt32(tri.c)
            let a = SIMD3<Double>(mesh.vertices[tri.a].x, mesh.vertices[tri.a].y, mesh.vertices[tri.a].z)
            let b = SIMD3<Double>(mesh.vertices[tri.b].x, mesh.vertices[tri.b].y, mesh.vertices[tri.b].z)
            let c = SIMD3<Double>(mesh.vertices[tri.c].x, mesh.vertices[tri.c].y, mesh.vertices[tri.c].z)
            let weighted = simd_cross(b - a, c - a)
            accumulated[tri.a] += weighted
            accumulated[tri.b] += weighted
            accumulated[tri.c] += weighted
        }
        var normals = [Float](repeating: 0, count: mesh.vertices.count * 3)
        for (i, n) in accumulated.enumerated() {
            let length = simd_length(n)
            let unit = length > 0 ? n / length : SIMD3<Double>(0, 0, 1)
            normals[i * 3] = Float(unit.x)
            normals[i * 3 + 1] = Float(unit.y)
            normals[i * 3 + 2] = Float(unit.z)
        }
        self.positions = positions.withUnsafeBytes { Data($0) }
        self.normals = normals.withUnsafeBytes { Data($0) }
        self.indices = indices.withUnsafeBytes { Data($0) }
        vertexCount = mesh.vertices.count
        triangleCount = mesh.triangles.count
    }

    @MainActor
    func makeNode() -> SCNNode {
        let float = MemoryLayout<Float>.size
        let positionSource = SCNGeometrySource(
            data: positions, semantic: .vertex, vertexCount: vertexCount, usesFloatComponents: true,
            componentsPerVector: 3, bytesPerComponent: float, dataOffset: 0, dataStride: float * 3
        )
        let normalSource = SCNGeometrySource(
            data: normals, semantic: .normal, vertexCount: vertexCount, usesFloatComponents: true,
            componentsPerVector: 3, bytesPerComponent: float, dataOffset: 0, dataStride: float * 3
        )
        let element = SCNGeometryElement(
            data: indices, primitiveType: .triangles, primitiveCount: triangleCount,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geometry = SCNGeometry(sources: [positionSource, normalSource], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.systemTeal
        material.isDoubleSided = true
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }
}

extension MeshRenderData {
    /// Validates `mesh`, then builds its render buffers off the main actor.
    static func prepare(_ mesh: ImportedMesh) async throws -> MeshRenderData {
        try await offMainActor {
            try MeshSchemaEnforcer.validate(mesh)
            return MeshRenderData(mesh)
        }
    }
}

import Foundation

struct MeshVertex: Sendable, Equatable {
    let x: Double
    let y: Double
    let z: Double
}

struct MeshTriangle: Sendable, Equatable {
    let a: Int
    let b: Int
    let c: Int
}

/// The standardized vertex/face arrays every provider returns. They map one-to-one onto the SwiftData schema:
/// `vertices[i]` becomes `ControlPoint(index: i)` and `triangles` is stored as JSON `[[Int]]` in `PatternPiece.faceIndexData`.
struct ImportedMesh: Sendable, Equatable {
    let vertices: [MeshVertex]
    let triangles: [MeshTriangle]
}

enum MeshIngestionError: LocalizedError, Equatable {
    case unsupportedFormat(String)
    case unreadableFile(String)
    case securityScopeDenied
    case fileTooLarge
    case unsupportedTopology(String)
    case noGeometry
    case invalidMesh(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            "\".\(ext)\" files are not supported. Choose an .stl, .obj, or .usdz file."
        case .unreadableFile(let reason):
            "The 3D file could not be read: \(reason)"
        case .securityScopeDenied:
            "The app was not granted access to the selected file."
        case .fileTooLarge:
            "The 3D file exceeds the 512 MB safety limit."
        case .unsupportedTopology(let kind):
            "The file contains \(kind) geometry, which cannot be used as a sewing surface."
        case .noGeometry:
            "The file does not contain any triangle geometry."
        case .invalidMesh(let reason):
            "The mesh is invalid: \(reason)"
        }
    }
}

/// Schema Enforcer: nothing reaches SwiftData or the topology engine unless it passes this check.
enum MeshSchemaEnforcer {
    static let maximumVertices = 2_000_000
    static let maximumTriangles = 4_000_000

    @discardableResult
    static func validate(_ mesh: ImportedMesh) throws -> ImportedMesh {
        guard !mesh.vertices.isEmpty, !mesh.triangles.isEmpty else { throw MeshIngestionError.noGeometry }
        guard mesh.vertices.count <= maximumVertices, mesh.triangles.count <= maximumTriangles else {
            throw MeshIngestionError.invalidMesh("it exceeds the vertex or triangle safety limit")
        }
        for (index, v) in mesh.vertices.enumerated() where !(v.x.isFinite && v.y.isFinite && v.z.isFinite) {
            throw MeshIngestionError.invalidMesh("vertex \(index) has a non-finite coordinate")
        }
        let count = mesh.vertices.count
        for (index, t) in mesh.triangles.enumerated() {
            guard (0..<count).contains(t.a), (0..<count).contains(t.b), (0..<count).contains(t.c) else {
                throw MeshIngestionError.invalidMesh("triangle \(index) references a vertex that does not exist")
            }
            guard t.a != t.b, t.b != t.c, t.a != t.c else {
                throw MeshIngestionError.invalidMesh("triangle \(index) repeats a vertex")
            }
            let a = mesh.vertices[t.a], b = mesh.vertices[t.b], c = mesh.vertices[t.c]
            let abx = b.x - a.x, aby = b.y - a.y, abz = b.z - a.z
            let acx = c.x - a.x, acy = c.y - a.y, acz = c.z - a.z
            let cx = aby * acz - abz * acy
            let cy = abz * acx - abx * acz
            let cz = abx * acy - aby * acx
            let doubledArea = (cx * cx + cy * cy + cz * cz).squareRoot()
            guard doubledArea.isFinite, doubledArea > 0 else {
                throw MeshIngestionError.invalidMesh("triangle \(index) is degenerate")
            }
        }
        return mesh
    }
}

extension ImportedMesh {
    /// JSON `[[Int]]`, the exact encoding `PatternPiece.faceIndexData` and `MeshTopology.load` expect.
    func faceIndexData() throws -> Data {
        try JSONEncoder().encode(triangles.map { [$0.a, $0.b, $0.c] })
    }

    /// Vertex and face arrays in the form `TopologyEngine.flatten` consumes. The mesh must already be validated.
    var topologyInput: (positions: [Vec3], triangles: [Int32]) {
        (
            vertices.map { Vec3($0.x, $0.y, $0.z) },
            triangles.flatMap { [Int32($0.a), Int32($0.b), Int32($0.c)] }
        )
    }
}

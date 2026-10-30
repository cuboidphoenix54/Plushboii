import Foundation
import ModelIO
import simd

@MainActor
final class LocalMeshProvider: MeshIngestionService {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    var sourceFormat: String { fileURL.pathExtension.lowercased() }
    var suggestedName: String { fileURL.deletingPathExtension().lastPathComponent }

    func ingest() async throws -> IngestedMesh {
        let url = fileURL
        let mesh = try await offMainActor { try ModelIOMeshReader.read(url) }
        let render = try await MeshRenderData.prepare(mesh)
        try Task.checkCancellation()
        return (render.makeNode(), mesh)
    }
}

/// Reads `.obj` and `.usdz` through `MDLAsset`. Everything here is blocking and must run off the main actor.
enum ModelIOMeshReader {
    static let maximumFileBytes = 512 * 1024 * 1024
    static let supportedExtensions: Set<String> = ["obj", "usdz"]

    private struct PositionKey: Hashable {
        let x: UInt32
        let y: UInt32
        let z: UInt32
    }

    static func read(_ url: URL) throws -> ImportedMesh {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext), MDLAsset.canImportFileExtension(ext) else {
            throw MeshIngestionError.unsupportedFormat(ext)
        }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw MeshIngestionError.securityScopeDenied }

        let size: Int
        do {
            size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        } catch {
            throw MeshIngestionError.unreadableFile(error.localizedDescription)
        }
        guard size > 0 else { throw MeshIngestionError.unreadableFile("the file is empty") }
        guard size <= maximumFileBytes else { throw MeshIngestionError.fileTooLarge }

        if ext == "usdz" {
            let handle: FileHandle
            do { handle = try FileHandle(forReadingFrom: url) } catch {
                throw MeshIngestionError.unreadableFile(error.localizedDescription)
            }
            defer { try? handle.close() }
            guard (try? handle.read(upToCount: 4)) == Data([0x50, 0x4B, 0x03, 0x04]) else {
                throw MeshIngestionError.unreadableFile("the file is not a valid USDZ archive")
            }
        }

        let asset = MDLAsset(url: url)
        let meshes = asset.childObjects(of: MDLMesh.self).compactMap { $0 as? MDLMesh }
        guard !meshes.isEmpty else { throw MeshIngestionError.noGeometry }

        var vertices: [MeshVertex] = []
        var triangles: [MeshTriangle] = []
        var welded: [PositionKey: Int] = [:]

        for mesh in meshes {
            try Task.checkCancellation()
            try append(mesh, vertices: &vertices, triangles: &triangles, welded: &welded)
        }
        return try MeshSchemaEnforcer.validate(ImportedMesh(vertices: vertices, triangles: triangles))
    }

    /// ModelIO duplicates a vertex wherever its normal or UV changes. The seam tool and the topology engine need one
    /// vertex per position, so identical (bit-exact) transformed positions are welded across all submeshes.
    private static func append(
        _ mesh: MDLMesh,
        vertices: inout [MeshVertex],
        triangles: inout [MeshTriangle],
        welded: inout [PositionKey: Int]
    ) throws {
        let vertexCount = mesh.vertexCount
        guard vertexCount > 0, vertexCount <= MeshSchemaEnforcer.maximumVertices * 4 else {
            throw MeshIngestionError.invalidMesh("a mesh has an unsupported vertex count")
        }
        guard let attribute = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else {
            throw MeshIngestionError.unreadableFile("a mesh has no position data")
        }
        guard attribute.stride >= 12, attribute.bufferSize >= (vertexCount - 1) * attribute.stride + 12 else {
            throw MeshIngestionError.unreadableFile("a mesh's position buffer is shorter than its vertex count")
        }
        let world = MDLTransform.globalTransform(with: mesh, atTime: 0)

        var remap = [Int](repeating: -1, count: vertexCount)
        func globalIndex(_ local: Int) throws -> Int {
            if remap[local] >= 0 { return remap[local] }
            let base = local * attribute.stride
            let x = attribute.dataStart.loadUnaligned(fromByteOffset: base, as: Float.self)
            let y = attribute.dataStart.loadUnaligned(fromByteOffset: base + 4, as: Float.self)
            let z = attribute.dataStart.loadUnaligned(fromByteOffset: base + 8, as: Float.self)
            let p = world * SIMD4<Float>(x, y, z, 1)
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else {
                throw MeshIngestionError.invalidMesh("vertex \(local) has a non-finite coordinate")
            }
            let key = PositionKey(x: (p.x + 0).bitPattern, y: (p.y + 0).bitPattern, z: (p.z + 0).bitPattern)
            let index: Int
            if let existing = welded[key] {
                index = existing
            } else {
                guard vertices.count < MeshSchemaEnforcer.maximumVertices else {
                    throw MeshIngestionError.invalidMesh("it exceeds the vertex safety limit")
                }
                index = vertices.count
                vertices.append(MeshVertex(x: Double(p.x), y: Double(p.y), z: Double(p.z)))
                welded[key] = index
            }
            remap[local] = index
            return index
        }

        let submeshes = (mesh.submeshes as? [MDLSubmesh]) ?? []
        for submesh in submeshes {
            let corners = try triangleCorners(of: submesh, vertexCount: vertexCount)
            guard triangles.count + corners.count / 3 <= MeshSchemaEnforcer.maximumTriangles else {
                throw MeshIngestionError.invalidMesh("it exceeds the triangle safety limit")
            }
            for t in stride(from: 0, to: corners.count, by: 3) {
                triangles.append(MeshTriangle(
                    a: try globalIndex(Int(corners[t])),
                    b: try globalIndex(Int(corners[t + 1])),
                    c: try globalIndex(Int(corners[t + 2]))
                ))
            }
        }
    }

    private static func triangleCorners(of submesh: MDLSubmesh, vertexCount: Int) throws -> [UInt32] {
        let count = submesh.indexCount
        guard count > 0 else { return [] }

        let buffer = submesh.indexBuffer
        let map = buffer.map()
        let raw = map.bytes
        let width: Int
        switch submesh.indexType {
        case .uInt8: width = 1
        case .uInt16: width = 2
        case .uInt32: width = 4
        default: throw MeshIngestionError.unreadableFile("a submesh has an unsupported index type")
        }
        guard buffer.length >= count * width else {
            throw MeshIngestionError.unreadableFile("a submesh's index buffer is shorter than its index count")
        }
        var source = [UInt32](repeating: 0, count: count)
        for i in 0..<count {
            switch width {
            case 1: source[i] = UInt32(raw.loadUnaligned(fromByteOffset: i, as: UInt8.self))
            case 2: source[i] = UInt32(raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
            default: source[i] = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
            }
        }
        guard source.allSatisfy({ Int($0) < vertexCount }) else {
            throw MeshIngestionError.invalidMesh("a face index is out of range")
        }

        switch submesh.geometryType {
        case .triangles:
            guard count % 3 == 0 else { throw MeshIngestionError.invalidMesh("a triangle list has a partial triangle") }
            return source
        case .quads:
            guard count % 4 == 0 else { throw MeshIngestionError.invalidMesh("a quad list has a partial quad") }
            var result: [UInt32] = []
            result.reserveCapacity(count / 4 * 6)
            for q in stride(from: 0, to: count, by: 4) {
                result += [source[q], source[q + 1], source[q + 2], source[q], source[q + 2], source[q + 3]]
            }
            return result
        case .variableTopology:
            guard let topology = submesh.topology, let faceBuffer = topology.faceTopology,
                  topology.faceCount > 0, faceBuffer.length >= topology.faceCount
            else {
                throw MeshIngestionError.unsupportedTopology("variable-topology")
            }
            let faceMap = faceBuffer.map()
            var result: [UInt32] = []
            var cursor = 0
            for face in 0..<topology.faceCount {
                let corners = Int(faceMap.bytes.loadUnaligned(fromByteOffset: face, as: UInt8.self))
                guard corners >= 3, cursor + corners <= count else {
                    throw MeshIngestionError.invalidMesh("a polygon face is malformed")
                }
                for k in 1..<(corners - 1) {
                    result += [source[cursor], source[cursor + k], source[cursor + k + 1]]
                }
                cursor += corners
            }
            return result
        case .triangleStrips:
            throw MeshIngestionError.unsupportedTopology("triangle-strip")
        case .lines:
            throw MeshIngestionError.unsupportedTopology("line")
        case .points:
            throw MeshIngestionError.unsupportedTopology("point")
        @unknown default:
            throw MeshIngestionError.unsupportedTopology("unknown")
        }
    }
}

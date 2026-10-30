import Foundation

enum STLMeshReader {
    private struct PositionKey: Hashable {
        let x: UInt64
        let y: UInt64
        let z: UInt64
    }

    static func read(_ data: Data) throws -> ImportedMesh {
        if data.count >= 84 {
            let triangleCount = Int(littleEndianUInt32(data, at: 80))
            let expectedSize = 84 + triangleCount * 50
            if expectedSize == data.count {
                return try readBinary(data, triangleCount: triangleCount)
            }
        }
        return try readASCII(data)
    }

    private static func readBinary(_ data: Data, triangleCount: Int) throws -> ImportedMesh {
        guard triangleCount <= MeshSchemaEnforcer.maximumTriangles else {
            throw MeshIngestionError.invalidMesh("it exceeds the triangle safety limit")
        }
        guard triangleCount > 0 else { throw MeshIngestionError.noGeometry }

        var vertices: [MeshVertex] = []
        var triangles: [MeshTriangle] = []
        var welded: [PositionKey: Int] = [:]
        vertices.reserveCapacity(min(triangleCount * 3, MeshSchemaEnforcer.maximumVertices))
        triangles.reserveCapacity(triangleCount)

        for triangleIndex in 0..<triangleCount {
            if triangleIndex.isMultiple(of: 4096) { try Task.checkCancellation() }
            let recordStart = 84 + triangleIndex * 50
            let firstVertex = recordStart + 12
            let a = try append(binaryVertex(data, at: firstVertex), to: &vertices, welded: &welded)
            let b = try append(binaryVertex(data, at: firstVertex + 12), to: &vertices, welded: &welded)
            let c = try append(binaryVertex(data, at: firstVertex + 24), to: &vertices, welded: &welded)
            triangles.append(MeshTriangle(a: a, b: b, c: c))
        }

        return try MeshSchemaEnforcer.validate(ImportedMesh(vertices: vertices, triangles: triangles))
    }

    private static func readASCII(_ data: Data) throws -> ImportedMesh {
        var vertices: [MeshVertex] = []
        var triangles: [MeshTriangle] = []
        var welded: [PositionKey: Int] = [:]
        var cursor = 0
        var pending: [Int] = []
        pending.reserveCapacity(3)

        try data.withUnsafeBytes { raw in
            while let token = nextToken(in: raw, cursor: &cursor) {
                guard tokenEquals("vertex", raw: raw, range: token) else { continue }
                var coordinates: [Double] = []
                coordinates.reserveCapacity(3)
                for _ in 0..<3 {
                    guard let numberToken = nextToken(in: raw, cursor: &cursor),
                          let value = Double(String(decoding: raw[numberToken], as: UTF8.self)),
                          value.isFinite
                    else {
                        throw MeshIngestionError.unreadableFile("the ASCII STL contains an invalid vertex")
                    }
                    coordinates.append(value)
                }
                let vertex = MeshVertex(x: coordinates[0], y: coordinates[1], z: coordinates[2])
                pending.append(try append(vertex, to: &vertices, welded: &welded))
                if pending.count == 3 {
                    guard triangles.count < MeshSchemaEnforcer.maximumTriangles else {
                        throw MeshIngestionError.invalidMesh("it exceeds the triangle safety limit")
                    }
                    triangles.append(MeshTriangle(a: pending[0], b: pending[1], c: pending[2]))
                    pending.removeAll(keepingCapacity: true)
                    if triangles.count.isMultiple(of: 4096) { try Task.checkCancellation() }
                }
            }
        }

        guard pending.isEmpty else {
            throw MeshIngestionError.unreadableFile("the ASCII STL has an incomplete triangle")
        }
        return try MeshSchemaEnforcer.validate(ImportedMesh(vertices: vertices, triangles: triangles))
    }

    private static func append(
        _ vertex: MeshVertex,
        to vertices: inout [MeshVertex],
        welded: inout [PositionKey: Int]
    ) throws -> Int {
        let key = PositionKey(
            x: vertex.x == 0 ? 0 : vertex.x.bitPattern,
            y: vertex.y == 0 ? 0 : vertex.y.bitPattern,
            z: vertex.z == 0 ? 0 : vertex.z.bitPattern
        )
        if let existing = welded[key] { return existing }
        guard vertices.count < MeshSchemaEnforcer.maximumVertices else {
            throw MeshIngestionError.invalidMesh("it exceeds the vertex safety limit")
        }
        let index = vertices.count
        vertices.append(vertex)
        welded[key] = index
        return index
    }

    private static func binaryVertex(_ data: Data, at offset: Int) -> MeshVertex {
        MeshVertex(
            x: Double(Float(bitPattern: littleEndianUInt32(data, at: offset))),
            y: Double(Float(bitPattern: littleEndianUInt32(data, at: offset + 4))),
            z: Double(Float(bitPattern: littleEndianUInt32(data, at: offset + 8)))
        )
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func nextToken(in bytes: UnsafeRawBufferPointer, cursor: inout Int) -> Range<Int>? {
        while cursor < bytes.count, isWhitespace(bytes[cursor]) { cursor += 1 }
        guard cursor < bytes.count else { return nil }
        let start = cursor
        while cursor < bytes.count, !isWhitespace(bytes[cursor]) { cursor += 1 }
        return start..<cursor
    }

    private static func tokenEquals(_ expected: StaticString, raw: UnsafeRawBufferPointer, range: Range<Int>) -> Bool {
        guard range.count == expected.utf8CodeUnitCount else { return false }
        return expected.withUTF8Buffer { expectedBytes in
            for index in 0..<range.count {
                let byte = raw[range.lowerBound + index]
                let folded = (65...90).contains(byte) ? byte + 32 : byte
                if folded != expectedBytes[index] { return false }
            }
            return true
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 9 || byte == 10 || byte == 11 || byte == 12 || byte == 13 || byte == 32
    }
}

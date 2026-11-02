import Foundation

enum OBJMeshReader {
    static func read(_ data: Data) throws -> ImportedMesh {
        guard let contents = String(data: data, encoding: .utf8) else {
            throw MeshIngestionError.unreadableFile("the OBJ is not valid UTF-8")
        }

        var vertices: [MeshVertex] = []
        var triangles: [MeshTriangle] = []
        var continuation = ""
        var lineNumber = 0
        var failure: Error?

        contents.enumerateLines { line, stop in
            lineNumber += 1
            if lineNumber.isMultiple(of: 4096) {
                do {
                    try Task.checkCancellation()
                } catch {
                    failure = error
                    stop = true
                    return
                }
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("\\") {
                continuation += trimmed.dropLast() + " "
                return
            }

            var logicalLine = continuation + trimmed
            continuation.removeAll(keepingCapacity: true)
            if lineNumber == 1, logicalLine.first == "\u{FEFF}" {
                logicalLine.removeFirst()
            }
            do {
                try parse(
                    logicalLine,
                    lineNumber: lineNumber,
                    vertices: &vertices,
                    triangles: &triangles
                )
            } catch {
                failure = error
                stop = true
            }
        }

        if let failure { throw failure }
        guard continuation.isEmpty else {
            throw MeshIngestionError.unreadableFile("the OBJ ends with an incomplete continued line")
        }
        return try MeshSchemaEnforcer.validate(ImportedMesh(vertices: vertices, triangles: triangles))
    }

    private static func parse(
        _ line: String,
        lineNumber: Int,
        vertices: inout [MeshVertex],
        triangles: inout [MeshTriangle]
    ) throws {
        let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let fields = content.split(whereSeparator: \.isWhitespace)
        guard let directive = fields.first else { return }

        switch directive {
        case "v":
            guard fields.count >= 4,
                  let x = Double(fields[1]), let y = Double(fields[2]), let z = Double(fields[3]),
                  x.isFinite, y.isFinite, z.isFinite
            else {
                throw MeshIngestionError.unreadableFile("the OBJ has an invalid vertex on line \(lineNumber)")
            }
            guard vertices.count < MeshSchemaEnforcer.maximumVertices else {
                throw MeshIngestionError.invalidMesh("it exceeds the vertex safety limit")
            }
            vertices.append(MeshVertex(x: x, y: y, z: z))

        case "f":
            guard fields.count >= 4 else {
                throw MeshIngestionError.unreadableFile("the OBJ has a face with fewer than three vertices on line \(lineNumber)")
            }
            var face: [Int] = []
            face.reserveCapacity(fields.count - 1)
            for field in fields.dropFirst() {
                let indexToken = field.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                guard let sourceIndex = Int(indexToken), sourceIndex != 0 else {
                    throw MeshIngestionError.unreadableFile("the OBJ has an invalid face index on line \(lineNumber)")
                }
                let index = sourceIndex > 0 ? sourceIndex - 1 : vertices.count + sourceIndex
                guard (0..<vertices.count).contains(index) else {
                    throw MeshIngestionError.unreadableFile("the OBJ has an out-of-range face index on line \(lineNumber)")
                }
                face.append(index)
            }
            guard triangles.count <= MeshSchemaEnforcer.maximumTriangles - (face.count - 2) else {
                throw MeshIngestionError.invalidMesh("it exceeds the triangle safety limit")
            }
            for corner in 1..<(face.count - 1) {
                triangles.append(MeshTriangle(a: face[0], b: face[corner], c: face[corner + 1]))
            }

        default:
            break
        }
    }
}

import XCTest
@testable import TopologyKit

final class MeshIngestionTests: XCTestCase {
    private func quad() -> ImportedMesh {
        ImportedMesh(
            vertices: [MeshVertex(x: 0, y: 0, z: 0), MeshVertex(x: 1, y: 0, z: 0), MeshVertex(x: 1, y: 1, z: 0), MeshVertex(x: 0, y: 1, z: 0)],
            triangles: [MeshTriangle(a: 0, b: 1, c: 2), MeshTriangle(a: 0, b: 2, c: 3)]
        )
    }

    func testValidMeshPassesAndEncodesAsPatternPieceFaceData() throws {
        let mesh = try MeshSchemaEnforcer.validate(quad())
        let decoded = try JSONDecoder().decode([[Int]].self, from: mesh.faceIndexData())
        XCTAssertEqual(decoded, [[0, 1, 2], [0, 2, 3]])
    }

    func testEnforcerRejectsEveryKindOfMalformedMesh() {
        let v = quad().vertices
        let cases: [ImportedMesh] = [
            ImportedMesh(vertices: [], triangles: []),
            ImportedMesh(vertices: v, triangles: []),
            ImportedMesh(vertices: v, triangles: [MeshTriangle(a: 0, b: 1, c: 9)]),
            ImportedMesh(vertices: v, triangles: [MeshTriangle(a: 0, b: 1, c: -1)]),
            ImportedMesh(vertices: v, triangles: [MeshTriangle(a: 0, b: 0, c: 1)]),
            ImportedMesh(vertices: [v[0], v[1], MeshVertex(x: 2, y: 0, z: 0)], triangles: [MeshTriangle(a: 0, b: 1, c: 2)]),
            ImportedMesh(vertices: [v[0], v[1], MeshVertex(x: .nan, y: 0, z: 0)], triangles: [MeshTriangle(a: 0, b: 1, c: 2)]),
            ImportedMesh(vertices: [v[0], v[1], MeshVertex(x: .infinity, y: 0, z: 0)], triangles: [MeshTriangle(a: 0, b: 1, c: 2)]),
        ]
        for (index, mesh) in cases.enumerated() {
            XCTAssertThrowsError(try MeshSchemaEnforcer.validate(mesh), "case \(index)")
        }
    }

    func testValidatedArraysReachTheTopologyEngine() throws {
        var vertices: [MeshVertex] = []
        var triangles: [MeshTriangle] = []
        let n = 6
        for j in 0...n { for i in 0...n { vertices.append(MeshVertex(x: Double(i), y: Double(j), z: 0)) } }
        for j in 0..<n { for i in 0..<n {
            let a = j * (n + 1) + i, b = a + 1, c = a + n + 1, d = c + 1
            triangles += [MeshTriangle(a: a, b: b, c: d), MeshTriangle(a: a, b: d, c: c)]
        } }
        let mesh = try MeshSchemaEnforcer.validate(ImportedMesh(vertices: vertices, triangles: triangles))
        let input = mesh.topologyInput
        XCTAssertEqual(input.positions.count, vertices.count)
        XCTAssertEqual(input.triangles.count, triangles.count * 3)
        let result = try TopologyEngine.flatten(positions: input.positions, triangles: input.triangles, seams: [])
        XCTAssertEqual(result.islands.count, 1)
        XCTAssertLessThan(result.islands[0].report.areaDelta, 1e-6)
    }

    func testASCIISTLIsTriangulatedAndWeldsSharedVertices() throws {
        let stl = """
        solid square
          facet normal 0 0 1
            outer loop
              vertex 0 0 0
              vertex 1 0 0
              vertex 1 1 0
            endloop
          endfacet
          facet normal 0 0 1
            outer loop
              vertex 0 0 0
              vertex 1 1 0
              vertex 0 1 0
            endloop
          endfacet
        endsolid square
        """

        let mesh = try STLMeshReader.read(Data(stl.utf8))

        XCTAssertEqual(mesh.vertices.count, 4)
        XCTAssertEqual(mesh.triangles, [MeshTriangle(a: 0, b: 1, c: 2), MeshTriangle(a: 0, b: 2, c: 3)])
    }

    func testBinarySTLIsReadAndWeldsSharedVertices() throws {
        var data = Data(repeating: 0, count: 134)
        data[80] = 1
        let coordinates: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
        for (index, coordinate) in coordinates.enumerated() {
            let offset = 96 + index * 4
            var bits = coordinate.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
        }

        let mesh = try STLMeshReader.read(data)

        XCTAssertEqual(mesh.vertices.count, 3)
        XCTAssertEqual(mesh.triangles, [MeshTriangle(a: 0, b: 1, c: 2)])
    }

    func testMalformedASCIISTLIsRejected() {
        XCTAssertThrowsError(try STLMeshReader.read(Data("solid broken vertex 0 1 endsolid".utf8)))
    }
}

import CoreML
import simd

final class LocalLRMTensorParserTests: XCTestCase {
    private func array(_ shape: [Int], _ values: [Float], type: MLMultiArrayDataType = .float32) throws -> MLMultiArray {
        let a = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: type)
        for (i, v) in values.enumerated() { a[i] = NSNumber(value: v) }
        return a
    }

    func testParsesBatchedVerticesAndFloatFaces() throws {
        let v = try array([1, 4, 3], [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0])
        let f = try array([2, 3], [0, 1, 2, 0, 2, 3])
        let mesh = try LocalLRMTensorParser.parse(vertices: v, faces: f)
        XCTAssertEqual(mesh.vertices.count, 4)
        XCTAssertEqual(mesh.triangles, [MeshTriangle(a: 0, b: 1, c: 2), MeshTriangle(a: 0, b: 2, c: 3)])
    }

    func testRejectsBadShapeAndFractionalFaces() throws {
        let f = try array([1, 3], [0, 1, 2])
        XCTAssertThrowsError(try LocalLRMTensorParser.parse(vertices: array([4, 2], [Float](repeating: 1, count: 8)), faces: f))
        let v = try array([3, 3], [0, 0, 0, 1, 0, 0, 0, 1, 0])
        XCTAssertThrowsError(try LocalLRMTensorParser.parse(vertices: v, faces: array([1, 3], [0, 1, 1.5])))
        XCTAssertThrowsError(try LocalLRMTensorParser.parse(vertices: v, faces: array([1, 3], [0, 1, 7])))
    }
}

final class MarchingTetrahedraTests: XCTestCase {
    func testSphereFieldYieldsClosedOutwardManifoldWithCorrectAreaAndVolume() throws {
        let n = 40, radius = 0.7
        var values = [Float](repeating: 0, count: n * n * n)
        let spacing = 2.0 / Double(n - 1)
        for z in 0..<n { for y in 0..<n { for x in 0..<n {
            let p = SIMD3<Double>(Double(x), Double(y), Double(z)) * spacing - SIMD3<Double>(repeating: 1)
            values[x + n * (y + n * z)] = Float(radius - (p.x * p.x + p.y * p.y + p.z * p.z).squareRoot())
        } } }
        let field = try ScalarField(resolution: n, values: values, origin: SIMD3<Double>(repeating: -1), spacing: spacing)
        let mesh = try MarchingTetrahedra.extract(field)

        var edgeUse = [UInt64: Int]()
        var area = 0.0, volume = 0.0
        for t in mesh.triangles {
            for (a, b) in [(t.a, t.b), (t.b, t.c), (t.c, t.a)] {
                edgeUse[UInt64(min(a, b)) << 32 | UInt64(max(a, b)), default: 0] += 1
            }
            let a = mesh.vertices[t.a], b = mesh.vertices[t.b], c = mesh.vertices[t.c]
            let pa = SIMD3<Double>(a.x, a.y, a.z), pb = SIMD3<Double>(b.x, b.y, b.z), pc = SIMD3<Double>(c.x, c.y, c.z)
            area += simd_length(simd_cross(pb - pa, pc - pa)) / 2
            volume += simd_dot(pa, simd_cross(pb, pc)) / 6
        }
        XCTAssertTrue(edgeUse.values.allSatisfy { $0 == 2 }, "every edge must be shared by exactly two triangles")
        XCTAssertEqual(area, 4 * Double.pi * radius * radius, accuracy: 4 * Double.pi * radius * radius * 0.03)
        XCTAssertEqual(volume, 4.0 / 3.0 * Double.pi * pow(radius, 3), accuracy: 4.0 / 3.0 * Double.pi * pow(radius, 3) * 0.03)
        for v in mesh.vertices {
            XCTAssertEqual((v.x * v.x + v.y * v.y + v.z * v.z).squareRoot(), radius, accuracy: 0.03)
        }
    }

    func testEmptyFieldAndNonFiniteFieldAreRejected() throws {
        let empty = try ScalarField(resolution: 4, values: [Float](repeating: -1, count: 64), origin: .zero, spacing: 1)
        XCTAssertThrowsError(try MarchingTetrahedra.extract(empty))
        let bad = try ScalarField(resolution: 4, values: [Float](repeating: .nan, count: 64), origin: .zero, spacing: 1)
        XCTAssertThrowsError(try MarchingTetrahedra.extract(bad))
    }
}

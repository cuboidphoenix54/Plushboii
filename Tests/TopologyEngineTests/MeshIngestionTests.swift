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
}

import XCTest
@testable import TopologyKit

final class MeshComponentSplitterTests: XCTestCase {
    func testDisconnectedMeshesAreSeparatedBeforeFlattening() throws {
        let positions = [
            Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
            Vec3(3, 0, 0), Vec3(4, 0, 0), Vec3(4, 1, 0), Vec3(3, 1, 0),
        ]
        let triangles: [Int32] = [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7]

        let components = try MeshComponentSplitter.split(
            positions: positions,
            triangles: triangles,
            seams: []
        )

        XCTAssertEqual(components.count, 2)
        XCTAssertEqual(components.map(\.triangleCount), [2, 2])
        XCTAssertEqual(components.reduce(0) { $0 + $1.surfaceArea }, 2, accuracy: 1e-12)
        XCTAssertEqual(components.flatMap(\.sourceVertices).sorted(), Array(0..<8))
        for component in components {
            XCTAssertTrue(component.triangles.allSatisfy {
                $0 >= 0 && Int($0) < component.positions.count
            })
        }
    }

    func testSeamCutSplitsOneConnectedMeshIntoIndependentPieces() throws {
        let positions = [
            Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
        ]
        let triangles: [Int32] = [0, 1, 2, 0, 2, 3]

        let components = try MeshComponentSplitter.split(
            positions: positions,
            triangles: triangles,
            seams: [[0, 2]]
        )

        XCTAssertEqual(components.count, 2)
        XCTAssertEqual(components.map(\.triangleCount), [1, 1])
        XCTAssertEqual(components.reduce(0) { $0 + $1.surfaceArea }, 1, accuracy: 1e-12)
        XCTAssertTrue(components.allSatisfy { $0.positions.count == 3 })
    }

    func testConnectedMeshWithoutSeparatingSeamsIsRejected() {
        XCTAssertThrowsError(
            try MeshComponentSplitter.split(
                positions: [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)],
                triangles: [0, 1, 2],
                seams: []
            )
        )
    }

    func testOffMeshSeamEdgeIsRejected() {
        XCTAssertThrowsError(
            try MeshComponentSplitter.split(
                positions: [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0)],
                triangles: [0, 1, 2, 0, 2, 3],
                seams: [[1, 3]]
            )
        )
    }
}

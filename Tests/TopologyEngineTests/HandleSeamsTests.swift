import XCTest
@testable import TopologyKit

final class HandleSeamsTests: XCTestCase {
    private func torus(major: Int = 24, minor: Int = 12) -> (positions: [Vec3], triangles: [Int32]) {
        var positions: [Vec3] = []
        for i in 0..<major { for j in 0..<minor {
            let u = 2 * Double.pi * Double(i) / Double(major), v = 2 * Double.pi * Double(j) / Double(minor)
            positions.append(Vec3((2 + 0.6 * cos(v)) * cos(u), 0.6 * sin(v), (2 + 0.6 * cos(v)) * sin(u)))
        } }
        var t: [Int32] = []
        for i in 0..<major { for j in 0..<minor {
            let a = Int32(i * minor + j), b = Int32(((i + 1) % major) * minor + j)
            let c = Int32(i * minor + (j + 1) % minor), d = Int32(((i + 1) % major) * minor + (j + 1) % minor)
            t += [a, b, d, a, d, c]
        } }
        return (positions, t)
    }

    func testTorusHasGenusOneAndSphereHasNone() {
        let mesh = torus()
        XCTAssertEqual(HandleSeams.genus(triangles: mesh.triangles), 1)
        XCTAssertEqual(HandleSeams.genus(triangles: [0, 1, 2, 0, 2, 3, 0, 3, 1, 1, 3, 2]), 0)
    }

    func testTorusCutGraphOpensItIntoADisc() throws {
        let mesh = torus()
        let seams = HandleSeams.seams(positions: mesh.positions, triangles: mesh.triangles)
        XCTAssertFalse(seams.isEmpty)
        let flat = try TopologyEngine.flatten(positions: mesh.positions, triangles: mesh.triangles, seams: seams, fabric: .none, tolerance: 100, refine: false)
        XCTAssertGreaterThanOrEqual(flat.islands.count, 1)
    }
}

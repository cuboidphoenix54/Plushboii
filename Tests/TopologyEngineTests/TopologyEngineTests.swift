import XCTest
@testable import TopologyKit

final class TopologyEngineTests: XCTestCase {
    private func grid(_ n: Int, _ f: (Double, Double) -> Vec3) -> ([Vec3], [Int32]) {
        var p: [Vec3] = []
        for j in 0...n { for i in 0...n { p.append(f(Double(i) / Double(n), Double(j) / Double(n))) } }
        var t: [Int32] = []
        for j in 0..<n { for i in 0..<n {
            let a = Int32(j * (n + 1) + i), b = a + 1, c = a + Int32(n + 1), d = c + 1
            t += [a, b, d, a, d, c]
        } }
        return (p, t)
    }

    private func dome() -> ([Vec3], [Int32]) {
        grid(16) { u, v in
            let th = (u - 0.5) * Double.pi * 0.45, ph = (v - 0.5) * Double.pi * 0.45
            return Vec3(sin(th) * cos(ph), sin(ph), cos(th) * cos(ph))
        }
    }

    func testFlatGridHasZeroDistortion() throws {
        let (p, t) = grid(8) { Vec3($0 * 2, $1, 0) }
        let r = try TopologyEngine.flatten(positions: p, triangles: t, seams: [])
        XCTAssertEqual(r.islands.count, 1)
        XCTAssertLessThan(r.islands[0].report.areaDelta, 1e-6)
    }

    func testOpenCylinderIsDevelopable() throws {
        let (p, t) = grid(12) { u, v in Vec3(cos(u * 1.8 * .pi), sin(u * 1.8 * .pi), v * 2) }
        let r = try TopologyEngine.flatten(positions: p, triangles: t, seams: [])
        XCTAssertLessThan(r.islands[0].report.areaDelta, 0.01)
    }

    func testDomeRigidAddsDartAndStaysWithinTolerance() throws {
        let (p, t) = dome()
        let r = try TopologyEngine.flatten(positions: p, triangles: t, seams: [], fabric: .rigid(maxDarts: 4))
        XCTAssertTrue(r.islands[0].report.passed)
        XCTAssertLessThanOrEqual(r.islands[0].report.areaDelta, 0.05)
        XCTAssertGreaterThanOrEqual(r.islands[0].darts.count, 1)
    }

    func testMinkyShrinksByStretchFactorAndVerifies() throws {
        let (p, t) = dome()
        let none = try TopologyEngine.flatten(positions: p, triangles: t, seams: [])
        let minky = try TopologyEngine.flatten(positions: p, triangles: t, seams: [], fabric: .twoWayStretch(warpPercent: 50, weftPercent: 40))
        XCTAssertTrue(minky.islands[0].report.passed)
        XCTAssertEqual(minky.islands[0].report.area2D / none.islands[0].report.area2D, 1 / (1.5 * 1.4), accuracy: 1e-6)
        XCTAssertTrue(minky.islands[0].darts.isEmpty)
    }

    func testStronglyCurvedSurfaceIsRejectedNotReturned() {
        let (p, t) = grid(16) { u, v in
            let th = (u - 0.5) * Double.pi * 0.9, ph = (v - 0.5) * Double.pi * 0.9
            return Vec3(sin(th) * cos(ph), sin(ph), cos(th) * cos(ph))
        }
        XCTAssertThrowsError(try TopologyEngine.flatten(positions: p, triangles: t, seams: []))
    }

    func testClosedMeshWithoutSeamsIsRejected() {
        let p: [Vec3] = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)]
        let t: [Int32] = [0, 2, 1, 0, 1, 3, 1, 2, 3, 0, 3, 2]
        XCTAssertThrowsError(try TopologyEngine.flatten(positions: p, triangles: t, seams: []))
    }

    func testSeamOffMeshIsRejected() {
        let (p, t) = grid(4) { Vec3($0, $1, 0) }
        XCTAssertThrowsError(try TopologyEngine.flatten(positions: p, triangles: t, seams: [[0, 24]]))
    }

    func testDeterminism() throws {
        let (p, t) = dome()
        let a = try TopologyEngine.flatten(positions: p, triangles: t, seams: [], fabric: .rigid(maxDarts: 4))
        let b = try TopologyEngine.flatten(positions: p, triangles: t, seams: [], fabric: .rigid(maxDarts: 4))
        XCTAssertEqual(a.islands[0].uv, b.islands[0].uv)
    }
}

import XCTest
@testable import TopologyKit

final class PlushAgentTests: XCTestCase {
    private func sphere(rings: Int, segments: Int) -> (positions: [Vec3], triangles: [Int32]) {
        var positions: [Vec3] = [Vec3(0, 1, 0)]
        for r in 1..<rings {
            let phi = Double.pi * Double(r) / Double(rings)
            for s in 0..<segments {
                let theta = 2 * Double.pi * Double(s) / Double(segments)
                positions.append(Vec3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta)))
            }
        }
        positions.append(Vec3(0, -1, 0))
        var tris: [Int32] = []
        for s in 0..<segments { tris += [0, Int32(1 + (s + 1) % segments), Int32(1 + s)] }
        for r in 0..<(rings - 2) {
            for s in 0..<segments {
                let a = Int32(1 + r * segments + s), b = Int32(1 + r * segments + (s + 1) % segments)
                let c = a + Int32(segments), d = b + Int32(segments)
                tris += [a, b, c, b, d, c]
            }
        }
        let last = Int32(positions.count - 1), base = Int32(1 + (rings - 2) * segments)
        for s in 0..<segments { tris += [last, base + Int32(s), base + Int32((s + 1) % segments)] }
        return (positions, tris)
    }

    func testSimplifierReachesTargetAndKeepsAreaAndValidIndices() {
        let mesh = sphere(rings: 40, segments: 60)
        let result = MeshSimplifier.simplify(positions: mesh.positions, triangles: mesh.triangles, targetFaces: 600)
        XCTAssertLessThanOrEqual(result.triangles.count / 3, 650)
        XCTAssertTrue(result.triangles.allSatisfy { $0 >= 0 && Int($0) < result.positions.count })
        let area = stride(from: 0, to: result.triangles.count, by: 3).reduce(0.0) { total, t in
            let a = result.positions[Int(result.triangles[t])], b = result.positions[Int(result.triangles[t + 1])], c = result.positions[Int(result.triangles[t + 2])]
            return total + 0.5 * vlength(vcross(b - a, c - a))
        }
        XCTAssertEqual(area, 4 * Double.pi, accuracy: 4 * Double.pi * 0.08)
        XCTAssertTrue(OpenPieceSeams.boundaryLoops(triangles: result.triangles).isEmpty)
    }

    func testAgentSimplifiesAndReportsOnObj() throws {
        let mesh = sphere(rings: 30, segments: 40)
        var text = ""
        for p in mesh.positions { text += "v \(p.x) \(p.y) \(p.z)\n" }
        for t in stride(from: 0, to: mesh.triangles.count, by: 3) { text += "f \(mesh.triangles[t] + 1) \(mesh.triangles[t + 1] + 1) \(mesh.triangles[t + 2] + 1)\n" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        var options = PlushAgentOptions()
        options.maximumFacesForSeamSolve = 0
        let report = try PlushAgent.run(input: url, options: options)
        XCTAssertEqual(report.originalFaces, mesh.triangles.count / 3)
        XCTAssertFalse(report.pieces.isEmpty)
        XCTAssertFalse(report.steps.isEmpty)
    }
}

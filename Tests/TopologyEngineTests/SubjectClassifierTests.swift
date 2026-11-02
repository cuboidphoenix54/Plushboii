import XCTest
@testable import TopologyKit

final class SubjectClassifierTests: XCTestCase {
    private func ball(scale: Vec3 = Vec3(1, 1, 1)) -> [Vec3] {
        var out: [Vec3] = []
        for r in 0...8 { for s in 0..<12 {
            let phi = Double.pi * Double(r) / 8, theta = 2 * Double.pi * Double(s) / 12
            out.append(Vec3(sin(phi) * cos(theta) * scale.x, cos(phi) * scale.y, sin(phi) * sin(theta) * scale.z))
        } }
        return out
    }

    private func joints(_ count: Int) -> [AnatomicalJoint] {
        (0..<count).map { AnatomicalJoint(name: "joint \($0)", position: Vec3(0, 0, 0), direction: Vec3(0, 1, 0), positiveLabel: "", negativeLabel: "") }
    }

    func testJointlessCompactShapeIsSinglePieceObject() {
        let result = SubjectClassifier.classify(positions: ball(), triangles: [], joints: [], mirrorMatch: 0.95)
        XCTAssertEqual(result.kind, .object)
        XCTAssertEqual(result.strategy, .singlePiece)
        XCTAssertNil(SubjectClassifier.objectCuts(for: result))
    }

    func testFlatShapeIsFrontBackObjectCutAcrossThinAxis() throws {
        let result = SubjectClassifier.classify(positions: ball(scale: Vec3(1, 1, 0.1)), triangles: [], joints: joints(1), mirrorMatch: 0.95)
        XCTAssertEqual(result.kind, .object)
        XCTAssertEqual(result.strategy, .frontBack)
        let cuts = try XCTUnwrap(SubjectClassifier.objectCuts(for: result))
        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts[0].axis, .z)
        XCTAssertEqual(cuts[0].normalizedPosition, 0.5, accuracy: 1e-9)
    }

    func testManyJointsIsCreature() {
        let result = SubjectClassifier.classify(positions: ball(), triangles: [], joints: joints(3), mirrorMatch: 0.95)
        XCTAssertEqual(result.kind, .creature)
        XCTAssertNil(result.strategy)
        XCTAssertNil(SubjectClassifier.objectCuts(for: result))
    }

    func testSingleJointAloneStaysObject() {
        XCTAssertEqual(SubjectClassifier.classify(positions: ball(), triangles: [], joints: joints(1), mirrorMatch: nil).kind, .object)
    }

    func testOverrideWinsAndIsRecorded() {
        let result = SubjectClassifier.classify(positions: ball(), triangles: [], joints: [], mirrorMatch: nil, override: .creature)
        XCTAssertEqual(result.kind, .creature)
        XCTAssertTrue(result.forced)
        XCTAssertTrue(result.reasons.contains { $0.contains("forced") })
    }
}

final class GoreSplitTests: XCTestCase {
    private func cone(rings: Int = 14, segments: Int = 32) -> (positions: [Vec3], triangles: [Int32]) {
        var p: [Vec3] = []
        for r in 0..<rings {
            let y = Double(r) / Double(rings), radius = 1 - y
            for s in 0..<segments {
                let a = 2 * Double.pi * Double(s) / Double(segments)
                p.append(Vec3(radius * cos(a), y * 4, radius * sin(a)))
            }
        }
        let apex = Int32(p.count); p.append(Vec3(0, 4, 0))
        let base = Int32(p.count); p.append(Vec3(0, 0, 0))
        var t: [Int32] = []
        for r in 0..<(rings - 1) { for s in 0..<segments {
            let a = Int32(r * segments + s), b = Int32(r * segments + (s + 1) % segments)
            let c = a + Int32(segments), d = b + Int32(segments)
            t += [a, c, b, b, c, d]
        } }
        for s in 0..<segments { t += [apex, Int32((rings - 1) * segments + s), Int32((rings - 1) * segments + (s + 1) % segments)] }
        for s in 0..<segments { t += [base, Int32((s + 1) % segments), Int32(s)] }
        return (p, t)
    }

    func testConeIsDetectedAsTaperedAndSplitsIntoBaseAndFourLeaves() throws {
        let mesh = cone()
        let analysis = SubjectClassifier.classify(positions: mesh.positions, triangles: mesh.triangles, joints: [], mirrorMatch: 0.95)
        XCTAssertEqual(analysis.strategy, .gores)
        XCTAssertEqual(analysis.taperAxis, .y)
        XCTAssertFalse(analysis.baseAtHigh)
        let pieces = try SubjectClassifier.goreComponents(positions: mesh.positions, triangles: mesh.triangles, axis: .y, baseAtHigh: false)
        XCTAssertEqual(pieces.count, 5)
        XCTAssertEqual(pieces.filter { $0.anatomicalLabel?.contains("mirrored") == true }.count, 2)
        XCTAssertEqual(pieces.filter { $0.anatomicalLabel?.contains("longer") == true }.count, 2)
    }
}

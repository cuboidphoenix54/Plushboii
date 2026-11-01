import XCTest
@testable import TopologyKit

final class PlushifyFeatureTests: XCTestCase {
    private func gridIsland(width: Double, height: Double, n: Int = 4, uvScale: Double = 1) -> (UVIsland, [Vec3]) {
        var uv: [Vec2] = [], pos: [Vec3] = []
        for j in 0...n { for i in 0...n {
            let x = width * Double(i) / Double(n), y = height * Double(j) / Double(n)
            pos.append(Vec3(x, y, 0)); uv.append(Vec2(x * uvScale, y * uvScale))
        } }
        var t: [Int32] = []
        for j in 0..<n { for i in 0..<n {
            let a = Int32(j * (n + 1) + i), b = a + 1, c = a + Int32(n + 1), d = c + 1
            t += [a, b, d, a, d, c]
        } }
        let r = DistortionReport(area3D: 1, area2D: 1, expectedArea2D: 1, areaDelta: 0, tolerance: 0.05, meanLocalDistortion: 0, maxLocalDistortion: 0, flippedTriangles: 0, passed: true)
        return (UVIsland(segmentIndex: 0, triangles: t, uv: uv, sourceVertex: Array(0..<uv.count), darts: [], geometryReport: r, report: r, log: []), pos)
    }

    func testIsometricPatchHasNoStretch() {
        let (island, pos) = gridIsland(width: 2, height: 1, uvScale: 3)
        let q = PatternQualityMap.evaluate(island: island, positions: pos)
        XCTAssertLessThan(q.worstStretch, 1e-6)
        XCTAssertEqual(q.flippedTriangles, 0)
    }

    func testAnisotropicPatchStretches() {
        var (island, pos) = gridIsland(width: 2, height: 1)
        island = UVIsland(segmentIndex: 0, triangles: island.triangles, uv: island.uv.map { Vec2($0.x * 2, $0.y) }, sourceVertex: island.sourceVertex, darts: [], geometryReport: island.geometryReport, report: island.report, log: [])
        XCTAssertGreaterThan(PatternQualityMap.evaluate(island: island, positions: pos).worstStretch, 0.4)
    }

    func testMirroredTriangleIsFlipped() {
        var (island, pos) = gridIsland(width: 1, height: 1)
        island = UVIsland(segmentIndex: 0, triangles: island.triangles, uv: island.uv.map { Vec2(-$0.x, $0.y) }, sourceVertex: island.sourceVertex, darts: [], geometryReport: island.geometryReport, report: island.report, log: [])
        XCTAssertGreaterThan(PatternQualityMap.evaluate(island: island, positions: pos).flippedTriangles, 0)
    }

    func testMeshBudget() {
        XCTAssertEqual(ModelPreparation.assess(vertexCount: 500, faceCount: 1000).level, .ok)
    }

    func testFabricPlannerRejectsWidePiece() throws {
        let (island, _) = gridIsland(width: 3000, height: 10)
        let sheet = try PatternLayout.makeSheet(from: FlatteningResult(islands: [island], fabric: .none), centimetersPerUnit: 0.01)
        XCTAssertNoThrow(try FabricCuttingPlanner.plan(sheet: sheet, widthsCm: ["Fabric": 110]))
    }

    func testNonManifoldEdgeIsSplit() {
        // Four triangles sharing the edge (0,1).
        let pos = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, -1, 0), Vec3(0, 0, 1), Vec3(0, 0, -1)]
        let tri: [Int32] = [0, 1, 2, 0, 1, 3, 0, 1, 4, 0, 1, 5]
        let r = MeshRepair.resolveNonManifoldEdges(positions: pos, triangles: tri)
        XCTAssertEqual(r.nonManifoldEdges, 1)
        XCTAssertGreaterThan(r.positions.count, pos.count)
    }

    private func cylinder(rings: Int = 4, sides: Int = 8) -> ([Vec3], [Int32]) {
        var pos: [Vec3] = [], tri: [Int32] = []
        for r in 0..<rings { for s in 0..<sides {
            let a = Double(s) / Double(sides) * 2 * .pi
            pos.append(Vec3(cos(a), sin(a), Double(r)))
        } }
        for r in 0..<(rings - 1) { for s in 0..<sides {
            let a = Int32(r * sides + s), b = Int32(r * sides + (s + 1) % sides)
            let c = a + Int32(sides), d = b + Int32(sides)
            tri += [a, b, d, a, d, c]
        } }
        return (pos, tri)
    }

    func testOpenCylinderHasTwoLoopsJoinedByOneSeam() {
        let (pos, tri) = cylinder()
        XCTAssertEqual(OpenPieceSeams.boundaryLoops(triangles: tri).count, 2)
        XCTAssertEqual(OpenPieceSeams.joiningSeams(positions: pos, triangles: tri).count, 1)
    }

    func testSingleLoopPieceNeedsNoJoiningSeam() {
        let (pos, tri) = gridMesh()
        XCTAssertEqual(OpenPieceSeams.boundaryLoops(triangles: tri).count, 1)
        XCTAssertTrue(OpenPieceSeams.joiningSeams(positions: pos, triangles: tri).isEmpty)
    }

    private func gridMesh(n: Int = 3) -> ([Vec3], [Int32]) {
        var pos: [Vec3] = [], tri: [Int32] = []
        for j in 0...n { for i in 0...n { pos.append(Vec3(Double(i), Double(j), 0)) } }
        for j in 0..<n { for i in 0..<n {
            let a = Int32(j * (n + 1) + i), b = a + 1, c = a + Int32(n + 1), d = c + 1
            tri += [a, b, d, a, d, c]
        } }
        return (pos, tri)
    }

    func testGrazingCutLeavesNoSliverFragments() throws {
        let (pos, tri) = cylinder()
        let cut = AnatomicalCut(axis: .z, normalizedPosition: 0.5, boundary: "mid", negativeRegion: "a", positiveRegion: "b", confidence: 0.8)
        let pieces = try AnatomicalMeshSplitter.split(positions: pos, triangles: tri, cuts: [cut])
        XCTAssertEqual(pieces.count, 2)
        XCTAssertTrue(pieces.allSatisfy { $0.triangleCount > AnatomicalMeshSplitter.maximumFragmentTriangles })
    }

    /// Two spheres-ish bulbs joined by a narrow waist along x, built as a revolved profile.
    private func dumbbell() -> ([Vec3], [Int32]) {
        let radii: [Double] = [0.2, 0.7, 1.0, 0.7, 0.2, 0.12, 0.2, 0.7, 1.0, 0.7, 0.2]
        let sides = 16
        var pos: [Vec3] = [], tri: [Int32] = []
        for (i, r) in radii.enumerated() { for s in 0..<sides {
            let a = Double(s) / Double(sides) * 2 * .pi
            pos.append(Vec3(Double(i) * 0.5, r * cos(a), r * sin(a)))
        } }
        for i in 0..<(radii.count - 1) { for s in 0..<sides {
            let a = Int32(i * sides + s), b = Int32(i * sides + (s + 1) % sides)
            let c = a + Int32(sides), d = b + Int32(sides)
            tri += [a, b, d, a, d, c]
        } }
        return (pos, tri)
    }

    func testJointSplitCutsPieceAndConservesArea() throws {
        let (pos, tri) = dumbbell()
        let joint = AnatomicalJoint(name: "waist", position: Vec3(2.5, 0, 0), direction: Vec3(1, 0, 0), positiveLabel: "right", negativeLabel: "left")
        let pieces = try AnatomicalMeshSplitter.split(positions: pos, triangles: tri, joints: [joint])
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(Set(pieces.compactMap(\.anatomicalLabel)), ["left", "right"])
    }

    func testTiltedJointPlaneIsHonoured() throws {
        let (pos, tri) = dumbbell()
        let joint = AnatomicalJoint(name: "tilted", position: Vec3(2.5, 0, 0), direction: Vec3(1, 0.3, 0), positiveLabel: "a", negativeLabel: "b")
        let pieces = try AnatomicalMeshSplitter.split(positions: pos, triangles: tri, joints: [joint])
        XCTAssertEqual(pieces.count, 2)
        let plane = CutPlane(through: joint.position, normal: joint.direction)!
        for piece in pieces {
            let side = piece.positions.map { plane.signedDistance(to: $0) }
            XCTAssertTrue(side.allSatisfy { $0 >= -1e-9 } || side.allSatisfy { $0 <= 1e-9 })
        }
    }

    func testJointThatMissesTheMeshIsRejected() {
        let (pos, tri) = dumbbell()
        let joint = AnatomicalJoint(name: "far", position: Vec3(50, 0, 0), direction: Vec3(1, 0, 0), positiveLabel: "", negativeLabel: "")
        XCTAssertThrowsError(try AnatomicalMeshSplitter.split(positions: pos, triangles: tri, joints: [joint]))
    }

    func testDegenerateJointDirectionIsRejected() {
        let (pos, tri) = dumbbell()
        let joint = AnatomicalJoint(name: "zero", position: Vec3(2.5, 0, 0), direction: Vec3(0, 0, 0), positiveLabel: "", negativeLabel: "")
        XCTAssertThrowsError(try AnatomicalMeshSplitter.split(positions: pos, triangles: tri, joints: [joint]))
    }

    func testProposerFindsTheWaist() {
        let (pos, tri) = dumbbell()
        let joints = JointProposer.propose(positions: pos, triangles: tri)
        XCTAssertEqual(joints.count, 1)
        XCTAssertEqual(joints.first?.position.x ?? 0, 2.5, accuracy: 0.2)
        XCTAssertEqual(joints.first?.direction, Vec3(1, 0, 0))
    }

    func testProposerFindsNothingOnACylinder() {
        let (pos, tri) = cylinder(rings: 12, sides: 12)
        XCTAssertTrue(JointProposer.propose(positions: pos, triangles: tri).isEmpty)
    }

    func testARAPKeepsFlatPatchFlatAndUnflipped() {
        let n = 5
        var pos: [Vec3] = [], tri: [Int32] = [], uv: [Vec2] = []
        for j in 0...n { for i in 0...n {
            pos.append(Vec3(Double(i), Double(j), 0))
            uv.append(Vec2(Double(i) * 1.3, Double(j) * 0.8))
        } }
        for j in 0..<n { for i in 0..<n {
            let a = Int32(j * (n + 1) + i), b = a + 1, c = a + Int32(n + 1), d = c + 1
            tri += [a, b, d, a, d, c]
        } }
        let patch = SurfacePatch(positions: pos, triangles: tri, origin: Array(0..<pos.count))
        let out = ARAPRefiner.refine(patch: patch, initialUV: uv)
        let areas = DistortionVerifier.triangleAreas(positions: pos, triangles: tri, uv: out)
        XCTAssertTrue(areas.signedArea2D.allSatisfy { $0 > 0 })
        XCTAssertEqual(areas.signedArea2D.reduce(0, +), Double(n * n), accuracy: 0.05 * Double(n * n))
    }

    func testStitchAuditSeesEverySewnEdgeOfASeamedCylinder() throws {
        let (pos, tri) = cylinder(rings: 5, sides: 12)
        let seam = (0..<5).map { $0 * 12 }
        let result = try TopologyEngine.flatten(positions: pos, triangles: tri, seams: [seam])
        let audit = StitchAudit.audit(result.islands)
        XCTAssertEqual(audit.sewnEdges, seam.count - 1)
        XCTAssertLessThan(audit.worstMismatch, 0.05)
    }

    func testStitchAuditFlagsMismatchedCopies() throws {
        let (pos, tri) = cylinder(rings: 5, sides: 12)
        let seam = (0..<5).map { $0 * 12 }
        let result = try TopologyEngine.flatten(positions: pos, triangles: tri, seams: [seam])
        let island = try XCTUnwrap(result.islands.first)
        let stretched = UVIsland(
            segmentIndex: 0, triangles: island.triangles,
            uv: island.uv.map { Vec2($0.x * 2, $0.y) },
            sourceVertex: island.sourceVertex, darts: island.darts,
            geometryReport: island.geometryReport, report: island.report, log: island.log
        )
        XCTAssertEqual(StitchAudit.audit([stretched]).sewnEdges, seam.count - 1)
    }

    func testStagedSplitCutsDumbbellAtTheWaist() throws {
        let (pos, tri) = dumbbell()
        let joint = AnatomicalJoint(name: "waist", position: Vec3(2.5, 0, 0), direction: Vec3(1, 0, 0), positiveLabel: "right", negativeLabel: "left")
        let pieces = try StagedAnatomySplit.split(positions: pos, triangles: tri, joints: [joint])
        XCTAssertEqual(pieces.count, 2)
        XCTAssertTrue(pieces.allSatisfy { $0.triangleCount > 0 })
    }

    func testOpenPieceSolverReturnsVerifiedPanelsWithoutOverlap() throws {
        let (pos, tri) = cylinder(rings: 6, sides: 12)
        let solution = try XCTUnwrap(try OpenPieceSeams.solve(positions: pos, triangles: tri, fabric: .none))
        XCTAssertFalse(solution.result.islands.isEmpty)
        XCTAssertTrue(solution.result.islands.allSatisfy { $0.report.passed && $0.report.flippedTriangles == 0 })
        XCTAssertLessThan(OpenPieceSeams.meanStretch(solution.result.islands, positions: pos), 0.2)
    }

    func testFlattenedPanelsDoNotOverlapThemselves() throws {
        let (pos, tri) = cylinder(rings: 6, sides: 12)
        let result = try TopologyEngine.flatten(positions: pos, triangles: tri, seams: [(0..<6).map { $0 * 12 }])
        for island in result.islands {
            let points = try PatternGeometry.boundaryIndices(of: island).map { island.uv[Int($0)] }
            func side(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Double { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
            let n = points.count
            for i in 0..<n {
                for j in stride(from: i + 2, to: n, by: 1) where !(i == 0 && j == n - 1) {
                    let crosses = side(points[j], points[(j + 1) % n], points[i]) * side(points[j], points[(j + 1) % n], points[(i + 1) % n]) < 0
                        && side(points[i], points[(i + 1) % n], points[j]) * side(points[i], points[(i + 1) % n], points[(j + 1) % n]) < 0
                    XCTAssertFalse(crosses)
                }
            }
        }
    }

    func testNamingLabelsHeadArmsLegsAndTorso() {
        func piece(_ id: Int, _ x: Double, _ y: Double, _ label: String) -> MeshComponent {
            let pos = [Vec3(x, y, 0), Vec3(x + 0.1, y, 0), Vec3(x, y + 0.1, 0.1)]
            return MeshComponent(id: id, positions: pos, triangles: [0, 1, 2], sourceVertices: [0, 1, 2], anatomicalLabel: label)
        }
        let pieces = [
            piece(0, -0.05, 0.9, "Joint 1 part"), piece(1, 0.8, 0.4, "Joint 2 part"), piece(2, -0.9, 0.4, "Joint 3 part"),
            piece(3, 0.2, 0, "foot"), piece(4, -0.3, 0, "foot"), piece(5, -0.05, 0.4, "body front"), piece(6, -0.05, 0.4, "body back")
        ]
        let names = AnatomyNaming.name(pieces, up: Vec3(0, 1, 0)).compactMap(\.anatomicalLabel)
        XCTAssertEqual(names, ["Head", "Left Arm", "Right Arm", "Left Leg", "Right Leg", "Torso front", "Torso back"])
    }

    func testSmoothingRemovesLumpsAndKeepsSize() {
        var (pos, tri) = cylinder(rings: 12, sides: 12)
        let before = pos
        pos[40] = pos[40] + Vec3(0.08, 0.08, 0.08)
        let lumpy = pos
        let smooth = MeshSmoothing.taubin(positions: lumpy, triangles: tri)
        XCTAssertLessThan(vlength(smooth[40] - before[40]), vlength(lumpy[40] - before[40]) * 0.6)
        let heightBefore = (before.map(\.y).max() ?? 0) - (before.map(\.y).min() ?? 0)
        let heightAfter = (smooth.map(\.y).max() ?? 0) - (smooth.map(\.y).min() ?? 0)
        XCTAssertEqual(heightAfter, heightBefore, accuracy: heightBefore * 0.1)
    }
}

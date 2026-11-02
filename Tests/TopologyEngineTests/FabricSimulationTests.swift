import XCTest
@testable import TopologyKit

final class FabricSimulationTests: XCTestCase {
    private func gridPatch(_ n: Int) -> SurfacePatch {
        var positions: [Vec3] = []
        for j in 0...n { for i in 0...n { positions.append(Vec3(Double(i), Double(j), 0)) } }
        var triangles: [Int32] = []
        for j in 0..<n {
            for i in 0..<n {
                let a = Int32(j * (n + 1) + i), b = a + 1, c = a + Int32(n + 1), d = c + 1
                triangles += [a, b, d, a, d, c]
            }
        }
        return SurfacePatch.whole(positions: positions, triangles: triangles)
    }

    private func uvSphere(open: Bool = false) -> (positions: [Vec3], triangles: [Int32]) {
        let rings = 12, segments = 16
        var p: [Vec3] = [Vec3(0, 0, -1)]
        for r in 1..<rings {
            let a = Double.pi * Double(r) / Double(rings)
            for s in 0..<segments {
                let b = 2 * Double.pi * Double(s) / Double(segments)
                p.append(Vec3(sin(a) * cos(b), sin(a) * sin(b), -cos(a)))
            }
        }
        p.append(Vec3(0, 0, 1))
        let top = Int32(p.count - 1)
        func v(_ r: Int, _ s: Int) -> Int32 { Int32(1 + (r - 1) * segments + (s % segments)) }
        var t: [Int32] = []
        for s in 0..<segments { t += [0, v(1, s + 1), v(1, s)] }
        for r in 1..<(rings - 1) {
            for s in 0..<segments {
                t += [v(r, s), v(r, s + 1), v(r + 1, s + 1), v(r, s), v(r + 1, s + 1), v(r + 1, s)]
            }
        }
        if !open { for s in 0..<segments { t += [top, v(rings - 1, s), v(rings - 1, s + 1)] } }
        return (p, t)
    }

    func testSLIMReducesDistortionWithoutFlips() throws {
        let patch = gridPatch(6)
        let start: [Vec2] = patch.positions.enumerated().map { index, q in
            let jitter = Double((index * 37) % 11) / 11.0 * 0.15 - 0.075
            return Vec2(q.x * 1.4 + q.y * 0.3 + jitter, q.y * 0.8 - jitter)
        }
        let before = try XCTUnwrap(SLIMRefiner.meanExcessEnergy(patch: patch, uv: start))
        let result = SLIMRefiner.refine(patch: patch, initialUV: start)
        let after = try XCTUnwrap(SLIMRefiner.meanExcessEnergy(patch: patch, uv: result))
        XCTAssertLessThan(after, before)
        XCTAssertLessThan(after, 0.05)
        let report = DistortionVerifier.verify(positions: patch.positions, triangles: patch.triangles, uv: result, areaFactor: 1, tolerance: 0.05, requireLocalAccuracy: false)
        XCTAssertEqual(report.flippedTriangles, 0)
    }

    func testSLIMReturnsInputWhenStartFlips() {
        let patch = gridPatch(2)
        var start = patch.positions.map { Vec2($0.x, $0.y) }
        start[4] = Vec2(-5, -5)
        XCTAssertEqual(SLIMRefiner.refine(patch: patch, initialUV: start), start)
    }

    func testStuffingRecoversASphereAndRejectsOpenMeshes() throws {
        let mesh = uvSphere()
        let result = try StuffingSimulator.simulate(positions: mesh.positions, triangles: mesh.triangles)
        XCTAssertEqual(result.volumeRatio, 1, accuracy: 0.08)
        XCTAssertLessThan(result.shapeDeviation, 0.08)

        let open = uvSphere(open: true)
        XCTAssertThrowsError(try StuffingSimulator.simulate(positions: open.positions, triangles: open.triangles)) {
            XCTAssertEqual($0 as? StuffingError, .notClosed)
        }
    }

    func testSmallerPatternHoldsLessStuffing() throws {
        let mesh = uvSphere()
        var rest: [UInt64: Double] = [:]
        for t in 0..<(mesh.triangles.count / 3) {
            for k in 0..<3 {
                let a = mesh.triangles[t * 3 + k], b = mesh.triangles[t * 3 + (k + 1) % 3]
                rest[SurfaceCutter.edgeKey(a, b)] = 0.7 * vlength(mesh.positions[Int(a)] - mesh.positions[Int(b)])
            }
        }
        let result = try StuffingSimulator.simulate(positions: mesh.positions, triangles: mesh.triangles, restLengths: rest)
        XCTAssertLessThan(result.volumeRatio, 0.9)
    }

    func testFabricPropertiesInferFromProfile() {
        XCTAssertEqual(FabricProperties.inferred(from: .twoWayStretch(warpPercent: 40, weftPercent: 20, grainAngle: 0)).warpStretchPercent, 40)
    }

    func testNestingRespectsWidthWithoutOverlap() throws {
        let pieces = [
            FabricNesting.Piece(id: 0, width: 40, height: 30, copies: 4),
            FabricNesting.Piece(id: 1, width: 25, height: 60),
            FabricNesting.Piece(id: 2, width: 90, height: 10, copies: 2),
        ]
        let layout = try FabricNesting.nest(pieces: pieces, fabricWidth: 112, gap: 1)
        XCTAssertEqual(layout.placements.count, 7)
        for p in layout.placements {
            XCTAssertGreaterThanOrEqual(p.x, -1e-9)
            XCTAssertLessThanOrEqual(p.x + p.width, 112 + 1e-9)
            XCTAssertLessThanOrEqual(p.y + p.height, layout.usedLength + 1e-9)
        }
        for (i, a) in layout.placements.enumerated() {
            for b in layout.placements[(i + 1)...] {
                let overlap = a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
                XCTAssertFalse(overlap)
            }
        }
        XCTAssertThrowsError(try FabricNesting.nest(pieces: [FabricNesting.Piece(id: 0, width: 200, height: 5)], fabricWidth: 112))
    }

    func testShapeNestingInterlocksAndNeverOverlaps() throws {
        // C shape: a 60 x 40 block with a 40 x 20 notch cut into its right side.
        let c: [Vec2] = [Vec2(0, 0), Vec2(60, 0), Vec2(60, 10), Vec2(20, 10), Vec2(20, 30), Vec2(60, 30), Vec2(60, 40), Vec2(0, 40)]
        let square: [Vec2] = [Vec2(0, 0), Vec2(12, 0), Vec2(12, 12), Vec2(0, 12)]
        let shapes = [FabricNesting.Shape(id: 0, outline: c), FabricNesting.Shape(id: 1, outline: square, copies: 3)]
        let layout = try FabricNesting.nestShapes(shapes, fabricWidth: 70, gap: 0.5)
        XCTAssertEqual(layout.placements.count, 4)
        let boxes = try FabricNesting.nest(
            pieces: [FabricNesting.Piece(id: 0, width: 60, height: 40), FabricNesting.Piece(id: 1, width: 12, height: 12, copies: 3)],
            fabricWidth: 70, gap: 0.5)
        XCTAssertLessThanOrEqual(layout.usedLength, boxes.usedLength + 1e-9)

        func inside(_ point: Vec2, _ outline: [Vec2]) -> Bool {
            var result = false
            var j = outline.count - 1
            for i in outline.indices {
                let a = outline[i], b = outline[j]
                if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { result.toggle() }
                j = i
            }
            return result
        }
        let placed: [[Vec2]] = layout.placements.map { p in
            shapes[p.id].outline.map { $0 + Vec2(p.x, p.y) }
        }
        for outline in placed {
            XCTAssertGreaterThanOrEqual(outline.map(\.x).min()!, -1e-9)
            XCTAssertLessThanOrEqual(outline.map(\.x).max()!, 70 + 1e-9)
            XCTAssertLessThanOrEqual(outline.map(\.y).max()!, layout.usedLength + 1e-9)
        }
        var x = 0.25
        while x < 70 {
            var y = 0.25
            while y < layout.usedLength {
                let hits = placed.filter { inside(Vec2(x, y), $0) }.count
                XCTAssertLessThanOrEqual(hits, 1, "overlap at \(x), \(y)")
                y += 0.5
            }
            x += 0.5
        }
    }
}

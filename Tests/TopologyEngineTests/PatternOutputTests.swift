import XCTest
@testable import TopologyKit

final class PatternOutputTests: XCTestCase {
    private func island(width: Double, height: Double, n: Int = 8, segment: Int = 0) -> UVIsland {
        var uv: [Vec2] = []
        for j in 0...n { for i in 0...n { uv.append(Vec2(width * Double(i) / Double(n), height * Double(j) / Double(n))) } }
        var t: [Int32] = []
        for j in 0..<n { for i in 0..<n {
            let a = Int32(j * (n + 1) + i), b = a + 1, c = a + Int32(n + 1), d = c + 1
            t += [a, b, d, a, d, c]
        } }
        let report = DistortionReport(area3D: 1, area2D: 1, expectedArea2D: 1, areaDelta: 0, tolerance: 0.05, meanLocalDistortion: 0, maxLocalDistortion: 0, flippedTriangles: 0, passed: true)
        return UVIsland(segmentIndex: segment, triangles: t, uv: uv, sourceVertex: Array(0..<uv.count), darts: [], geometryReport: report, report: report, log: [])
    }

    private func disc(radius: Double, sides: Int) -> UVIsland {
        var uv: [Vec2] = [Vec2(0, 0)]
        for k in 0..<sides { let a = 2 * Double.pi * Double(k) / Double(sides); uv.append(Vec2(radius * cos(a), radius * sin(a))) }
        var t: [Int32] = []
        for k in 0..<sides { t += [0, Int32(1 + k), Int32(1 + (k + 1) % sides)] }
        let report = DistortionReport(area3D: 1, area2D: 1, expectedArea2D: 1, areaDelta: 0, tolerance: 0.05, meanLocalDistortion: 0, maxLocalDistortion: 0, flippedTriangles: 0, passed: true)
        return UVIsland(segmentIndex: 0, triangles: t, uv: uv, sourceVertex: Array(0..<uv.count), darts: [], geometryReport: report, report: report, log: [])
    }

    private func distanceToPolygon(_ p: Vec2, _ poly: [Vec2]) -> Double {
        var best = Double.infinity
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count], ab = b - a
            let t = min(1, max(0, vdot(p - a, ab) / vdot(ab, ab)))
            best = min(best, vlength(p - (a + ab * t)))
        }
        return best
    }

    func testBoundaryLoopOfSquareIsCounterClockwisePerimeter() throws {
        let loop = try PatternGeometry.boundaryLoop(of: island(width: 2, height: 1))
        XCTAssertEqual(loop.count, 32)
        var area = 0.0
        for i in loop.indices { let a = loop[i], b = loop[(i + 1) % loop.count]; area += a.x * b.y - b.x * a.y }
        XCTAssertEqual(area / 2, 2, accuracy: 1e-9)
    }

    func testSquareKeepsFourCornersAndOffsetsByQuarterInch() throws {
        let side = 200.0
        let boundary = try PatternGeometry.boundaryLoop(of: island(width: side, height: side))
        let seam = PatternGeometry.smoothClosedPath(through: boundary)
        XCTAssertEqual(seam.cornerAtStart.filter { $0 }.count, 4)
        let d = PatternUnits.seamAllowancePoints
        XCTAssertEqual(d, 18)
        let offset = try PatternGeometry.offset(seam, distance: d, segmentIndex: 0)
        XCTAssertEqual(offset.unresolvedConcaveJoins, 0)
        let b = offset.path.bounds
        XCTAssertEqual(b.minX, -d, accuracy: 1e-6)
        XCTAssertEqual(b.maxX, side + d, accuracy: 1e-6)
        XCTAssertEqual(b.minY, -d, accuracy: 1e-6)
        XCTAssertEqual(b.maxY, side + d, accuracy: 1e-6)
    }

    func testCircleOffsetIsUniformToWithinTolerance() throws {
        let radius = 150.0
        let boundary = try PatternGeometry.boundaryLoop(of: disc(radius: radius, sides: 48))
        let seam = PatternGeometry.smoothClosedPath(through: boundary)
        XCTAssertFalse(seam.cornerAtStart.contains(true))
        let d = 18.0
        let offset = try PatternGeometry.offset(seam, distance: d, segmentIndex: 0)
        let seamSamples = seam.sampled(perSegment: 24)
        for p in offset.path.sampled(perSegment: 8) {
            XCTAssertEqual(distanceToPolygon(p, seamSamples), d, accuracy: 0.1)
        }
    }

    func testOffsetStaysOutsideAndConstantOnLShapeConcaveCorner() throws {
        let poly: [Vec2] = [Vec2(0, 0), Vec2(100, 0), Vec2(100, 40), Vec2(40, 40), Vec2(40, 100), Vec2(0, 100)]
        let seam = PatternGeometry.smoothClosedPath(through: poly)
        let offset = try PatternGeometry.offset(seam, distance: 18, segmentIndex: 0)
        XCTAssertEqual(offset.unresolvedConcaveJoins, 0)
        let seamSamples = seam.sampled(perSegment: 24)
        // Mitered convex corners legitimately reach 18 * sqrt(2); nothing may ever come closer than 18.
        for p in offset.path.sampled(perSegment: 16) {
            let distance = distanceToPolygon(p, seamSamples)
            XCTAssertGreaterThanOrEqual(distance, 18 - 0.05, "point \(p)")
            XCTAssertLessThanOrEqual(distance, 18 * 2.0.squareRoot() + 0.05, "point \(p)")
        }
        XCTAssertTrue(offset.path.sampled(perSegment: 16).contains { abs(distanceToPolygon($0, seamSamples) - 18) < 0.05 && $0.x > 40 && $0.x < 100 && abs($0.y - 58) < 1 })
    }

    func testTightConcaveCurveIsRejectedNotReturned() {
        // Radius-2 concave notch cannot carry an 18 pt allowance.
        var poly: [Vec2] = []
        for k in 0..<24 {
            let a = 2 * Double.pi * Double(k) / 24
            poly.append(Vec2(2 * cos(a), 2 * sin(a)))
        }
        let reversedHole = ClosedBezierPath(
            segments: PatternGeometry.smoothClosedPath(through: poly.reversed()).segments,
            cornerAtStart: [Bool](repeating: false, count: 24)
        )
        XCTAssertThrowsError(try PatternGeometry.offset(reversedHole, distance: 18, segmentIndex: 0))
    }

    func testSheetHasLockedCalibrationSquareAndIgnoresScale() throws {
        let result = FlatteningResult(islands: [island(width: 10, height: 6)], fabric: .none)
        let a = try PatternLayout.makeSheet(from: result, centimetersPerUnit: 1)
        let b = try PatternLayout.makeSheet(from: result, centimetersPerUnit: 2)
        for sheet in [a, b] {
            XCTAssertEqual(sheet.calibration.width, 5 / 2.54 * 72, accuracy: 1e-9)
            XCTAssertEqual(sheet.calibration.height, 5 / 2.54 * 72, accuracy: 1e-9)
        }
        let seamA = a.pieces[0].seamLine.bounds, seamB = b.pieces[0].seamLine.bounds
        XCTAssertEqual(seamA.width, 10 * PatternUnits.pointsPerCentimeter, accuracy: 1e-6)
        XCTAssertEqual(seamB.width, 20 * PatternUnits.pointsPerCentimeter, accuracy: 1e-6)
        let cutA = a.pieces[0].cutLine.bounds
        XCTAssertEqual(cutA.width - seamA.width, 36, accuracy: 1e-6)
        XCTAssertFalse(cutA.intersects(a.calibration))
    }

    func testInvalidScaleAndOversizedPatternAreRejected() {
        let result = FlatteningResult(islands: [island(width: 10, height: 6)], fabric: .none)
        XCTAssertThrowsError(try PatternLayout.makeSheet(from: result, centimetersPerUnit: 0))
        XCTAssertThrowsError(try PatternLayout.makeSheet(from: result, centimetersPerUnit: .nan))
        XCTAssertThrowsError(try PatternLayout.makeSheet(from: result, centimetersPerUnit: 500)) { error in
            XCTAssertEqual(error as? PatternOutputError, .doesNotFitA0)
        }
        XCTAssertThrowsError(try PatternLayout.makeSheet(from: FlatteningResult(islands: [], fabric: .none), centimetersPerUnit: 1))
    }

    func testTilePlanNumbersPagesSequentiallyAndSkipsBlankTiles() throws {
        let result = FlatteningResult(islands: [island(width: 40, height: 30, segment: 0), island(width: 15, height: 15, segment: 1)], fabric: .none)
        let sheet = try PatternLayout.makeSheet(from: result, centimetersPerUnit: 1)
        let plan = TilePlan(sheet: sheet)
        XCTAssertGreaterThan(plan.tiles.count, 1)
        XCTAssertEqual(plan.tiles.map(\.pageNumber), Array(1...plan.tiles.count))
        XCTAssertLessThanOrEqual(plan.tiles.count, plan.rows * plan.columns)
        XCTAssertEqual(plan.tiles[0].row, 0)
        XCTAssertEqual(plan.tiles[0].column, 0)
        // The calibration square must sit wholly inside the first tile so it is never split across pages.
        XCTAssertLessThanOrEqual(sheet.calibration.maxX, TilePlan.windowSize.x)
        XCTAssertLessThanOrEqual(sheet.calibration.maxY, TilePlan.windowSize.y)
    }
}

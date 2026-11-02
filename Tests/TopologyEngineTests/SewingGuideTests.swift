import XCTest
@testable import TopologyKit

final class SewingGuideTests: XCTestCase {
    private func square(side: Double, darts: [Dart] = []) -> UVIsland {
        let n = 6
        var uv: [Vec2] = []
        for j in 0...n { for i in 0...n { uv.append(Vec2(side * Double(i) / Double(n), side * Double(j) / Double(n))) } }
        var t: [Int32] = []
        for j in 0..<n { for i in 0..<n {
            let a = Int32(j * (n + 1) + i), b = a + 1, c = a + Int32(n + 1), d = c + 1
            t += [a, b, d, a, d, c]
        } }
        let report = DistortionReport(area3D: 1, area2D: 1, expectedArea2D: 1, areaDelta: 0.01, tolerance: 0.05, meanLocalDistortion: 0, maxLocalDistortion: 0, flippedTriangles: 0, passed: true)
        return UVIsland(segmentIndex: 0, triangles: t, uv: uv, sourceVertex: Array(0..<uv.count), darts: darts, geometryReport: report, report: report, log: [])
    }

    private func fabric() -> FabricProfile { .none }

    func testAllowanceOptionsIncludeQuarterInchDefault() {
        XCTAssertEqual(SeamAllowanceOption.standard.points, PatternUnits.seamAllowancePoints, accuracy: 1e-9)
        XCTAssertEqual(SeamAllowanceOption.halfInch.points, 36, accuracy: 1e-9)
        XCTAssertEqual(SeamAllowanceOption.oneCentimeter.points, PatternUnits.pointsPerCentimeter, accuracy: 1e-9)
        XCTAssertEqual(Set(SeamAllowanceOption.allCases.map(\.points)).count, SeamAllowanceOption.allCases.count)
    }

    func testCutLineFollowsChosenAllowance() throws {
        let result = FlatteningResult(islands: [square(side: 10)], fabric: fabric())
        for option in [SeamAllowanceOption.quarterInch, .halfInch, .fiveEighthsInch] {
            var options = LayoutOptions()
            options.seamAllowancePoints = option.points
            let sheet = try PatternLayout.makeSheet(from: result, centimetersPerUnit: 1, options: options)
            let piece = try XCTUnwrap(sheet.pieces.first)
            let expected = 10 * PatternUnits.pointsPerCentimeter + 2 * option.points
            XCTAssertEqual(piece.cutLine.bounds.width, expected, accuracy: 1.5)
            XCTAssertEqual(piece.seamAllowancePoints, option.points, accuracy: 1e-9)
        }
    }

    func testJoinTechniqueThresholds() {
        XCTAssertEqual(JoinNote.technique(forMismatch: 0.02), .match)
        XCTAssertEqual(JoinNote.technique(forMismatch: 0.08), .ease)
        XCTAssertEqual(JoinNote.technique(forMismatch: 0.2), .gather)
        XCTAssertEqual(JoinNote.technique(forMismatch: 0.5), .recut)
    }

    func testDartNoteReportsDimensionsAndApex() throws {
        let dart = Dart(apexVertex: 10, pathVertices: [10, 3], openingAngle: Double.pi / 6, mouthWidth: 0.5, legLength: 2)
        let result = FlatteningResult(islands: [square(side: 10, darts: [dart])], fabric: fabric())
        let notes = SewingGuide.notes(for: result, centimetersPerUnit: 2)
        let note = try XCTUnwrap(notes.first?.darts.first)
        XCTAssertEqual(note.depthCentimeters, 4, accuracy: 1e-9)
        XCTAssertEqual(note.widthCentimeters, 1, accuracy: 1e-9)
        XCTAssertEqual(note.angleDegrees, 30, accuracy: 1e-9)

        var options = LayoutOptions()
        options.includeSewingNotes = true
        let sheet = try PatternLayout.makeSheet(from: result, centimetersPerUnit: 2, options: options)
        let piece = try XCTUnwrap(sheet.pieces.first)
        XCTAssertEqual(piece.dartApexes.count, 1)
        XCTAssertTrue(piece.notes.contains { $0.hasPrefix("Dart 1") })
    }

    func testGalleryBuildsOneCardPerPanelWithAllowance() throws {
        let result = FlatteningResult(islands: [square(side: 10), square(side: 5)], fabric: fabric())
        let cards = try PanelGallery.cards(pieceName: "Head", result: result, centimetersPerUnit: 1, seamAllowancePoints: SeamAllowanceOption.halfInch.points)
        XCTAssertEqual(cards.count, 2)
        XCTAssertTrue(cards.allSatisfy { $0.pieceName == "Head" })
        let big = try XCTUnwrap(cards.max { $0.widthCentimeters < $1.widthCentimeters })
        XCTAssertEqual(big.widthCentimeters, 10 + 2 * 1.27, accuracy: 0.1)
        XCTAssertEqual(big.cutLine.bounds.minX, 0, accuracy: 1e-6)
    }
}

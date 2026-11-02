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

    func testCurvatureOfSquareAndCircle() {
        let square = [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)]
        for outline in [square, square.reversed()] {
            let c = AllowanceCurvature.measure(outline: Array(outline))
            XCTAssertEqual(c.convexTurning, 2 * .pi, accuracy: 1e-9)
            XCTAssertEqual(c.concaveTurning, 0, accuracy: 1e-9)
        }
        let circle = (0..<72).map { Vec2(cos(Double($0) * .pi / 36), sin(Double($0) * .pi / 36)) }
        let c = AllowanceCurvature.measure(outline: circle)
        XCTAssertEqual(c.excessCentimeters(allowanceCentimeters: 0.64), 2 * .pi * 0.64, accuracy: 1e-6)
        XCTAssertEqual(c.notchCount, 24)
    }

    func testConcaveCornerCountsAsClip() {
        let l: [Vec2] = [Vec2(0, 0), Vec2(2, 0), Vec2(2, 1), Vec2(1, 1), Vec2(1, 2), Vec2(0, 2)]
        let c = AllowanceCurvature.measure(outline: l)
        XCTAssertEqual(c.concaveTurning, .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(c.convexTurning, 2.5 * .pi, accuracy: 1e-9)
    }

    func testStretchKnitToleratesLargerMismatch() {
        XCTAssertEqual(JoinNote.technique(forMismatch: 0.12), .gather)
        XCTAssertEqual(JoinNote.technique(forMismatch: 0.12, fabric: .stretchKnit), .ease)
        XCTAssertEqual(JoinNote.technique(forMismatch: 0.04, fabric: .stretchKnit), .match)
        XCTAssertEqual(JoinNote.technique(forMismatch: 0.04), .ease)
        XCTAssertEqual(JoinNote.technique(forMismatch: 0.02, fabric: .stretchKnit), .match)
    }

    func testGoreGuidanceWidth() {
        let g = SubjectClassifier.goreGuidance(maxRadius: 1)
        XCTAssertEqual(g.widthAtCurrent, .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(g.recommendedCount, 6)
        XCTAssertEqual(g.widthAtRecommended, .pi / 3, accuracy: 1e-9)
    }

    func testTortuosityStraightVersusWiggly() {
        let pts = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(2, 0, 0), Vec3(3, 0, 0)]
        XCTAssertEqual(SeamRules.tortuosity(path: [0, 1, 2, 3], positions: pts), 1, accuracy: 1e-9)
        let zig = [Vec3(0, 0, 0), Vec3(1, 1, 0), Vec3(2, 0, 0), Vec3(3, 1, 0), Vec3(4, 0, 0)]
        XCTAssertGreaterThan(SeamRules.tortuosity(path: [0, 1, 2, 3, 4], positions: zig), 1.3)
    }

    func testUniformityAndCuttingNotes() {
        let groups = [
            PieceCongruence.Group(representative: 0, members: [.init(island: 0, mirrored: false), .init(island: 1, mirrored: true)]),
            PieceCongruence.Group(representative: 2, members: [.init(island: 2, mirrored: false)])
        ]
        XCTAssertEqual(SeamRules.uniformity(groups, pieceCount: 3), 2.0 / 3.0, accuracy: 1e-9)
        let notes = SeamRules.cuttingNotes(groups: groups) { "leaf \($0)" }
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].contains("1 mirrored"))
    }

    func testVisibilityDerivedFromFaceLabelsPenalizesFaceSeams() {
        let cut = AnatomicalCut(axis: .y, normalizedPosition: 0.5, boundary: "neck", negativeRegion: "Body", positiveRegion: "Face", confidence: 1)
        let regions = SeamVisibility.derived(from: [cut])
        XCTAssertEqual(regions.count, 1)
        let pts = [Vec3(0, 0, 0), Vec3(0, 1, 0), Vec3(0, 0.1, 0), Vec3(0, 0.4, 0), Vec3(0, 0.6, 0), Vec3(0, 0.9, 0)]
        let visibility = SeamVisibility(regions: regions).bound(to: pts)
        XCTAssertEqual(visibility.penalty(of: [[2, 3]], positions: pts), 0, accuracy: 1e-9)
        XCTAssertEqual(visibility.penalty(of: [[4, 5]], positions: pts), 1, accuracy: 1e-9)
        XCTAssertEqual(SeamVisibility.none.penalty(of: [[4, 5]], positions: pts), 0)
    }

    func testCorrectionReplacesCutsAndRecordsTrainingRow() throws {
        let json = #"{"summary":"fixed","cuts":[{"axis":"y","normalizedPosition":0.4,"boundary":"neck","negativeRegion":"Body","positiveRegion":"Head","confidence":1}],"visibleRegions":[{"name":"face","min":[0,0.5,0],"max":[1,1,1],"weight":1}]}"#
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("corr-\(UUID().uuidString).json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        let correction = try AnatomyCorrection.load(file)
        let cuts = try XCTUnwrap(correction.replacementCuts)
        XCTAssertEqual(cuts.count, 1)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("learn-\(UUID().uuidString)")
        let views = [Data([1, 2]), Data([3]), Data([4])]
        let name = try AnatomyCorrectionStore.record(views: views, summary: "fixed", cuts: cuts, to: dir)
        _ = try AnatomyCorrectionStore.record(views: views, summary: "fixed again", cuts: cuts, to: dir)
        let lines = try String(contentsOf: dir.appendingPathComponent("corrections.jsonl")).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains(name))
        XCTAssertTrue(lines[0].contains("fixed again"))
        XCTAssertThrowsError(try AnatomyCorrectionStore.record(views: [], summary: "", cuts: cuts, to: dir))
    }

    func testMergeCorrectionsBuildsNewDatasetWithoutTouchingBase() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("merge-\(UUID().uuidString)")
        let base = root.appendingPathComponent("base"), corr = root.appendingPathComponent("corr"), out = root.appendingPathComponent("out")
        try fm.createDirectory(at: base.appendingPathComponent("creature_0000"), withIntermediateDirectories: true)
        try "{\"a\":1}\n{\"a\":2}\n".write(to: base.appendingPathComponent("train.jsonl"), atomically: true, encoding: .utf8)
        try "{\"v\":1}\n".write(to: base.appendingPathComponent("valid.jsonl"), atomically: true, encoding: .utf8)
        let cut = AnatomicalCut(axis: .y, normalizedPosition: 0.4, boundary: "neck", negativeRegion: "Body", positiveRegion: "Head", confidence: 1)
        try AnatomyCorrectionStore.record(views: [Data([1]), Data([2]), Data([3])], summary: "s", cuts: [cut], to: corr)
        let counts = try AnatomyCorrectionStore.merge(base: base, corrections: corr, into: out, repeatCount: 2)
        XCTAssertEqual(counts.baseTrain, 2)
        XCTAssertEqual(counts.added, 2)
        let train = try String(contentsOf: out.appendingPathComponent("train.jsonl")).split(separator: "\n")
        XCTAssertEqual(train.count, 4)
        XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("train.jsonl")).split(separator: "\n").count, 2)
        XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent("creature_0000").path))
        XCTAssertThrowsError(try AnatomyCorrectionStore.merge(base: base, corrections: corr, into: out))
    }
}

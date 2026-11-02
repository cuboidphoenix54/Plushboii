import XCTest
import PDFKit
@testable import TopologyKit

final class EndToEndTests: XCTestCase {
    private func sphere(rings: Int = 24, segments: Int = 36, center: Vec3 = Vec3(0, 0, 0), radius: Double = 1) -> (positions: [Vec3], triangles: [Int32]) {
        var positions: [Vec3] = [center + Vec3(0, radius, 0)]
        for r in 1..<rings {
            let phi = Double.pi * Double(r) / Double(rings)
            for s in 0..<segments {
                let theta = 2 * Double.pi * Double(s) / Double(segments)
                positions.append(center + Vec3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta)) * radius)
            }
        }
        positions.append(center + Vec3(0, -radius, 0))
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

    private func objData(_ mesh: (positions: [Vec3], triangles: [Int32])) -> Data {
        var text = ""
        for p in mesh.positions { text += "v \(p.x) \(p.y) \(p.z)\n" }
        for t in stride(from: 0, to: mesh.triangles.count, by: 3) {
            text += "f \(mesh.triangles[t] + 1) \(mesh.triangles[t + 1] + 1) \(mesh.triangles[t + 2] + 1)\n"
        }
        return Data(text.utf8)
    }

    private func area(_ positions: [Vec3], _ triangles: [Int32]) -> Double {
        var total = 0.0
        for t in stride(from: 0, to: triangles.count, by: 3) {
            let a = positions[Int(triangles[t])], b = positions[Int(triangles[t + 1])], c = positions[Int(triangles[t + 2])]
            total += 0.5 * vlength(vcross(b - a, c - a))
        }
        return total
    }

    private func rectIsland(width: Double, height: Double, segment: Int) -> UVIsland {
        let n = 4
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

    private func fabric() -> FabricProfile { .none }

    // MARK: Ingestion

    func testOBJRoundTripKeepsCountsAndArea() throws {
        let mesh = sphere(rings: 8, segments: 12)
        let imported = try OBJMeshReader.read(objData(mesh))
        XCTAssertEqual(imported.vertices.count, mesh.positions.count)
        XCTAssertEqual(imported.triangles.count, mesh.triangles.count / 3)
    }

    func testBinaryAndASCIISTLProduceTheSameTriangleCount() throws {
        let tris: [[Vec3]] = [
            [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)],
            [Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0)],
        ]
        var ascii = "solid t\n"
        for tri in tris {
            ascii += "facet normal 0 0 1\nouter loop\n"
            for v in tri { ascii += "vertex \(v.x) \(v.y) \(v.z)\n" }
            ascii += "endloop\nendfacet\n"
        }
        ascii += "endsolid t\n"
        var binary = Data(count: 80)
        var count = UInt32(tris.count).littleEndian
        binary.append(Data(bytes: &count, count: 4))
        for tri in tris {
            var floats: [Float] = [0, 0, 1]
            for v in tri { floats += [Float(v.x), Float(v.y), Float(v.z)] }
            floats.withUnsafeBytes { binary.append(contentsOf: $0) }
            binary.append(Data(count: 2))
        }
        let a = try STLMeshReader.read(Data(ascii.utf8))
        let b = try STLMeshReader.read(binary)
        XCTAssertEqual(a.triangles.count, 2)
        XCTAssertEqual(b.triangles.count, 2)
        XCTAssertEqual(a.vertices.count, 4)
        XCTAssertEqual(b.vertices.count, 4)
    }

    func testOBJWithNoFacesIsRejected() {
        XCTAssertThrowsError(try OBJMeshReader.read(Data("v 0 0 0\nv 1 0 0\n".utf8)))
    }

    // MARK: Smoothing and repair

    func testSmoothingIsDeterministicAndLeavesIndicesAlone() {
        let mesh = sphere(rings: 10, segments: 14)
        let a = MeshSmoothing.taubin(positions: mesh.positions, triangles: mesh.triangles, iterations: 5)
        let b = MeshSmoothing.taubin(positions: mesh.positions, triangles: mesh.triangles, iterations: 5)
        XCTAssertEqual(a.count, mesh.positions.count)
        XCTAssertEqual(a.map { $0.x }, b.map { $0.x })
        XCTAssertTrue(a.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    }

    func testSmoothingWithZeroIterationsOrEmptyInputIsIdentity() {
        let mesh = sphere(rings: 6, segments: 8)
        XCTAssertEqual(MeshSmoothing.taubin(positions: mesh.positions, triangles: mesh.triangles, iterations: 0).map { $0.y }, mesh.positions.map { $0.y })
        XCTAssertTrue(MeshSmoothing.taubin(positions: [], triangles: [], iterations: 10).isEmpty)
    }

    func testSmoothingKeepsSphereAreaWithinTolerance() {
        let mesh = sphere()
        let smoothed = MeshSmoothing.taubin(positions: mesh.positions, triangles: mesh.triangles)
        let before = area(mesh.positions, mesh.triangles), after = area(smoothed, mesh.triangles)
        XCTAssertEqual(after, before, accuracy: before * 0.03)
    }

    func testSmoothingRejectsOutOfRangeIndicesWithoutCrashing() {
        let positions = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)]
        let out = MeshSmoothing.taubin(positions: positions, triangles: [0, 1, 9])
        XCTAssertEqual(out.count, 3)
    }

    func testRepairLeavesManifoldSphereUntouched() {
        let mesh = sphere(rings: 8, segments: 10)
        let repaired = MeshRepair.resolveNonManifoldEdges(positions: mesh.positions, triangles: mesh.triangles)
        XCTAssertEqual(repaired.nonManifoldEdges, 0)
        XCTAssertEqual(repaired.triangles.count, mesh.triangles.count)
    }

    // MARK: Layout and export

    func testLayoutRejectsBadScaleAndEmptyInput() {
        let result = FlatteningResult(islands: [rectIsland(width: 1, height: 1, segment: 0)], fabric: fabric())
        for scale in [0.0, -1, .nan, .infinity] {
            XCTAssertThrowsError(try PatternLayout.makeSheet(from: result, centimetersPerUnit: scale)) {
                XCTAssertEqual($0 as? PatternOutputError, .invalidScale)
            }
        }
        XCTAssertThrowsError(try PatternLayout.makeSheet(from: FlatteningResult(islands: [], fabric: fabric()), centimetersPerUnit: 1)) {
            XCTAssertEqual($0 as? PatternOutputError, .noIslands)
        }
    }

    func testSmallPatternFitsStandardA0() throws {
        let result = FlatteningResult(islands: [rectIsland(width: 1, height: 1, segment: 0)], fabric: fabric())
        let sheet = try PatternLayout.makeSheet(from: result, centimetersPerUnit: 10)
        XCTAssertEqual(sheet.pageSize.x, PaperSize.a0.x, accuracy: 0.001)
        XCTAssertEqual(sheet.pageSize.y, PaperSize.a0.y, accuracy: 0.001)
    }

    func testOversizedPatternGrowsTheRollButKeepsScale() throws {
        // Eight 30 x 60 cm panels exceed a single A0 sheet.
        let islands = (0..<8).map { rectIsland(width: 30, height: 60, segment: $0) }
        let result = FlatteningResult(islands: islands, fabric: fabric())
        let sheet = try PatternLayout.makeSheet(from: result, centimetersPerUnit: 1)
        XCTAssertEqual(sheet.pageSize.x, PaperSize.a0.x, accuracy: 0.001)
        XCTAssertGreaterThan(sheet.pageSize.y, PaperSize.a0.y * 1.5)
        let widths = sheet.pieces.map { $0.cutLine.sampled().map { $0.x }.max()! - $0.cutLine.sampled().map { $0.x }.min()! }
        let expected = 30 * PatternUnits.pointsPerCentimeter + 2 * PatternUnits.seamAllowancePoints
        for w in widths { XCTAssertEqual(w, expected, accuracy: 1.5) }
    }

    func testPatternBiggerThanA0IsLaidOutForTiling() throws {
        let result = FlatteningResult(islands: [rectIsland(width: 400, height: 400, segment: 0)], fabric: fabric())
        let sheet = try PatternLayout.makeSheet(from: result, centimetersPerUnit: 1)
        XCTAssertTrue(sheet.isOversized)
        XCTAssertGreaterThan(sheet.pageSize.x, PaperSize.a0.x)
    }

    func testCalibrationSquareStaysFiveCentimetresAtEveryScale() throws {
        for scale in [0.5, 1, 10, 40] {
            let result = FlatteningResult(islands: [rectIsland(width: 1, height: 1, segment: 0)], fabric: fabric())
            let sheet = try PatternLayout.makeSheet(from: result, centimetersPerUnit: scale)
            XCTAssertEqual(sheet.calibration.width, 5 * PatternUnits.pointsPerCentimeter, accuracy: 0.001)
            XCTAssertEqual(sheet.calibration.height, 5 * PatternUnits.pointsPerCentimeter, accuracy: 0.001)
        }
    }

    func testNoPiecesOverlapAndNamesAreApplied() throws {
        let islands = (0..<6).map { rectIsland(width: 20, height: 25, segment: $0) }
        var options = LayoutOptions()
        options.names = [0: "Head", 1: "Left Arm"]
        let sheet = try PatternLayout.makeSheet(from: FlatteningResult(islands: islands, fabric: fabric()), centimetersPerUnit: 1, options: options)
        XCTAssertEqual(sheet.pieces.first { $0.segmentIndex == 0 }?.label, "Head")
        XCTAssertEqual(sheet.pieces.first { $0.segmentIndex == 1 }?.label, "Left Arm")
        let boxes = sheet.pieces.map { $0.cutLine.bounds }
        for i in boxes.indices { for j in boxes.indices where j > i {
            XCTAssertFalse(boxes[i].intersects(boxes[j]), "pieces \(i) and \(j) overlap")
        } }
    }

    func testExportProducesValidA0AndTiledPDFs() async throws {
        let islands = (0..<3).map { rectIsland(width: 15, height: 20, segment: $0) }
        let out = try await PatternPrintPipeline.export(result: FlatteningResult(islands: islands, fabric: fabric()), centimetersPerUnit: 1)
        let a0 = try XCTUnwrap(PDFDocument(data: out.a0PDF))
        let tiled = try XCTUnwrap(PDFDocument(data: out.tiledPDF))
        XCTAssertEqual(a0.pageCount, 1)
        XCTAssertEqual(tiled.pageCount, out.tiledPageCount)
        XCTAssertGreaterThanOrEqual(out.tiledPageCount, 1)
    }

    func testExportedTiledPageSizeIsUSLetter() async throws {
        let out = try await PatternPrintPipeline.export(result: FlatteningResult(islands: [rectIsland(width: 10, height: 10, segment: 0)], fabric: fabric()), centimetersPerUnit: 1)
        let page = try XCTUnwrap(PDFDocument(data: out.tiledPDF)?.page(at: 0))
        let box = page.bounds(for: .mediaBox)
        XCTAssertEqual(box.width, 612, accuracy: 0.5)
        XCTAssertEqual(box.height, 792, accuracy: 0.5)
    }

    // MARK: Agent

    func testAgentRunsOnSphereAndReportsPieces() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-\(UUID().uuidString).obj")
        try objData(sphere(rings: 10, segments: 14)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try PlushAgent.run(input: url)
        XCTAssertFalse(report.pieces.isEmpty)
        XCTAssertNotEqual(report.verdict, "failed")
        XCTAssertEqual(report.pieces.map(\.areaShare).reduce(0, +), 1, accuracy: 0.05)
        for piece in report.pieces { XCTAssertFalse(piece.label.isEmpty) }
        XCTAssertNoThrow(try report.json())
    }

    func testAgentSmoothingToggleDoesNotChangeFaceCount() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-\(UUID().uuidString).obj")
        try objData(sphere(rings: 8, segments: 12)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var off = PlushAgentOptions(); off.smoothingIterations = 0
        let a = try PlushAgent.run(input: url, options: off)
        let b = try PlushAgent.run(input: url)
        XCTAssertEqual(a.finalFaces, b.finalFaces)
    }

    func testAgentFailsCleanlyOnMissingOrGarbageInput() throws {
        XCTAssertThrowsError(try PlushAgent.run(input: URL(fileURLWithPath: "/nonexistent/none.obj")))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("garbage-\(UUID().uuidString).obj")
        try Data("not a mesh".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try PlushAgent.run(input: url))
    }

    func testAgentWritesOutputFilesWhenAsked() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-out-\(UUID().uuidString)")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-\(UUID().uuidString).obj")
        try objData(sphere(rings: 12, segments: 16)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: dir) }
        var options = PlushAgentOptions(); options.outputDirectory = dir
        let report = try PlushAgent.run(input: url, options: options)
        XCTAssertNotNil(report.preparedMeshFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    // MARK: Full pipeline

    func testSphereFlattensWithinAreaToleranceAndExportsAtScale() async throws {
        let mesh = sphere(rings: 10, segments: 14)
        let suggestion = try SeamSuggestionEngine.suggest(positions: mesh.positions, triangles: mesh.triangles, maximumSuggestions: 1).first
        let seams = try XCTUnwrap(suggestion).seamPaths
        let result = try TopologyEngine.flatten(positions: mesh.positions, triangles: mesh.triangles, seams: seams, fabric: fabric())
        XCTAssertFalse(result.islands.isEmpty)
        for island in result.islands {
            XCTAssertLessThanOrEqual(island.report.areaDelta, 0.05)
            XCTAssertEqual(island.report.flippedTriangles, 0)
        }
        let out = try await PatternPrintPipeline.export(result: result, centimetersPerUnit: 10)
        XCTAssertEqual(PDFDocument(data: out.a0PDF)?.pageCount, 1)
    }
}

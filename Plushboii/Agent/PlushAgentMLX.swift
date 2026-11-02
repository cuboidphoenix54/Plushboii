import Foundation

public struct PlushAgentMLXResult: Sendable {
    public let report: PlushAgentReport
    public let summary: String
    public let cuts: [String]
    public let patternFiles: [String]
}

extension PlushAgent {
    /// Full headless run driven by the MLX anatomy model: prepares the mesh, renders the three registered views,
    /// asks the MLX server for cut planes, splits, finds seams per piece, then lays out SVG and A0 PDF patterns.
    public static func runWithMLX(
        input url: URL,
        options: PlushAgentOptions = PlushAgentOptions(),
        adapterPath: String?,
        advisorModel: String? = nil,
        plushHeightCentimeters: Double = 50
    ) async throws -> PlushAgentMLXResult {
        guard let directory = options.outputDirectory else { throw PlushAgentError.unreadable("MLX runs need --out DIR.") }
        if let adapterPath { UserDefaults.standard.set(adapterPath, forKey: "mlxvlm.adapterPath") }

        // Pass 1 prepares the mesh (simplify, smooth, orient) and writes prepared.obj, which is what the model must see.
        let preparedDirectory = directory.appendingPathComponent("pass1", isDirectory: true)
        var first = options
        first.outputDirectory = preparedDirectory
        let probe = try run(input: url, options: first)
        guard let file = probe.preparedMeshFile else { throw PlushAgentError.unreadable("The prepared mesh was not written.") }
        let preparedURL = preparedDirectory.appendingPathComponent(file)
        let prepared = try OBJMeshReader.read(try Data(contentsOf: preparedURL)).topologyInput

        // Objects (masks, tools) have no anatomy; skip the MLX anatomy call and let the agent treat them as objects.
        if probe.subjectKind == SubjectKind.object.rawValue {
            let report = try run(input: url, options: options)
            return try await exportPattern(report: report, summary: "Object (\(probe.subjectReasons.joined(separator: " "))) — no anatomical cuts.", cuts: [], prepared: prepared.positions, directory: directory, options: options, plushHeightCentimeters: plushHeightCentimeters)
        }

        let views = try AnatomyMeshViewRenderer.render(positions: prepared.positions, triangles: prepared.triangles)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (view, data) in zip(AnatomyMeshViewRenderer.View.allCases, views) {
            try data.write(to: directory.appendingPathComponent("\(view.rawValue).png"))
        }
        let plan = try await OnDeviceSeamAdvisor.suggestAnatomy(views: views, model: advisorModel ?? OnDeviceSeamAdvisor.mlxModelName)

        let correction = try options.correctionsFile.map(AnatomyCorrection.load)
        var finalCuts = plan.cuts
        var summary = plan.summary
        if let replacement = correction?.replacementCuts {
            finalCuts = replacement
            summary = correction?.summary ?? "User-corrected anatomy."
            if let learn = options.learnDirectory {
                let name = try AnatomyCorrectionStore.record(views: views, summary: summary, cuts: replacement, to: learn)
                print("  learn: saved correction \(name) to \(learn.path)/corrections.jsonl")
            }
        }
        var second = options
        second.anatomyCuts = finalCuts
        second.visibility = SeamVisibility(regions: SeamVisibility.derived(from: finalCuts) + (correction?.visibleRegions ?? []))
        // Pass 2 re-runs the identical preparation, then cuts at the MLX planes.
        let report = try run(input: url, options: second)
        let cutLines = finalCuts.map {
            String(format: "%@ @ %.2f: %@ | %@ (%@, conf %.2f)", "\($0.axis)", $0.normalizedPosition, $0.negativeRegion, $0.positiveRegion, $0.boundary, $0.confidence)
        }

        return try await exportPattern(report: report, summary: summary, cuts: cutLines, prepared: prepared.positions, directory: directory, options: options, plushHeightCentimeters: plushHeightCentimeters)
    }

    /// Combines every piece's panels into one sheet at the requested plush height.
    private static func exportPattern(
        report inputReport: PlushAgentReport, summary: String, cuts cutLines: [String], prepared preparedPositions: [Vec3],
        directory: URL, options: PlushAgentOptions, plushHeightCentimeters: Double
    ) async throws -> PlushAgentMLXResult {
        var report = inputReport
        let fabric: FabricProfile
        if let maximumDarts = options.rigidMaximumDarts {
            fabric = .rigid(maxDarts: maximumDarts)
        } else if let warp = options.warpStretchPercent, let weft = options.weftStretchPercent {
            fabric = .twoWayStretch(warpPercent: warp, weftPercent: weft)
        } else {
            fabric = .none
        }
        var islands: [UVIsland] = []
        var names: [Int: String] = [:]
        for piece in report.pieces {
            guard piece.seamPaths != nil, let pieceFile = piece.file else { continue }
            let mesh = try OBJMeshReader.read(try Data(contentsOf: directory.appendingPathComponent(pieceFile))).topologyInput
            let seamFile = directory.appendingPathComponent("piece_\(piece.index + 1)_seams.json")
            guard let local = try? JSONDecoder().decode([[Int]].self, from: Data(contentsOf: seamFile)) else { continue }
            let flat: FlatteningResult
            do {
                flat = try TopologyEngine.flatten(positions: mesh.positions, triangles: mesh.triangles, seams: local, fabric: fabric)
            } catch {
                print("  ! \(piece.label): pattern flatten failed: \(error.localizedDescription)")
                continue
            }
            for (k, island) in flat.islands.enumerated() {
                let index = islands.count
                islands.append(UVIsland(
                    segmentIndex: index, triangles: island.triangles, uv: island.uv, sourceVertex: island.sourceVertex,
                    darts: island.darts, geometryReport: island.geometryReport, report: island.report, log: island.log
                ))
                names[index] = "\(piece.label) - panel \(k + 1)"
            }
        }
        var files: [String] = []
        if !islands.isEmpty {
            let height = (preparedPositions.map(\.y).max() ?? 1) - (preparedPositions.map(\.y).min() ?? 0)
            let scale = plushHeightCentimeters / max(height, 1e-9)
            var layout = LayoutOptions()
            layout.names = names
            layout.seamAllowancePoints = options.seamAllowancePoints
            layout.includeSewingNotes = false
            let sheet: PatternSheet
            do {
                sheet = try PatternLayout.makeSheet(from: FlatteningResult(islands: islands, fabric: fabric), centimetersPerUnit: scale, options: layout)
            } catch PatternOutputError.doesNotFitA0 {
                report.warnings.append(String(
                    format: "Pattern export skipped: at %.0f cm tall the pieces do not fit on one A0 sheet. Cut the largest piece into smaller sections or lower the plush height, then export again.",
                    plushHeightCentimeters))
                return PlushAgentMLXResult(report: report, summary: summary, cuts: cutLines, patternFiles: [])
            }
            try Data(PatternSVGExporter.svg(sheet).utf8).write(to: directory.appendingPathComponent("pattern.svg"))
            try Data(PatternDXFExporter.dxf(sheet).utf8).write(to: directory.appendingPathComponent("pattern.dxf"))
            try await PatternPDFExporter.a0PDF(sheet).write(to: directory.appendingPathComponent("pattern_a0.pdf"))
            files = ["pattern.svg", "pattern.dxf", "pattern_a0.pdf"]
            let pointsPerCentimeter = PatternUnits.pointsPerCentimeter
            let shapes = sheet.pieces.enumerated().map { index, piece -> FabricNesting.Shape in
                let outline = piece.cutLine.sampled(perSegment: 8).map { Vec2($0.x / pointsPerCentimeter, $0.y / pointsPerCentimeter) }
                return FabricNesting.Shape(id: index, outline: outline, copies: max(piece.copies, 1))
            }
            do {
                let nested = try FabricNesting.nestShapes(shapes, fabricWidth: options.fabricWidthCentimeters)
                report.construction.append(String(
                    format: "Fabric needed: about %.0f cm (%.2f yd) of %.0f cm wide fabric, %.0f%% covered (pieces interlock on a 1 cm grid, no rotation; add 10%% for pile direction and mistakes).",
                    nested.usedLength, nested.usedLength / 91.44, nested.fabricWidth, nested.efficiency * 100))
            } catch {
                report.warnings.append("Fabric estimate skipped: \(error.localizedDescription)")
            }
        }
        return PlushAgentMLXResult(report: report, summary: summary, cuts: cutLines, patternFiles: files)
    }
}

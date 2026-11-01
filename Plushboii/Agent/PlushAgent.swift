import Foundation

/// Headless plush-pattern agent: takes an OBJ and drives it through the same pipeline the app uses —
/// validate, assess, simplify, orient, find joints, cut, suggest seams — and reports every decision.
public struct PlushAgentOptions: Sendable {
    /// Meshes above this face count are decimated to it. Defaults to the app's recommended vertex budget.
    public var targetFaces: Int = 20_000
    /// Upper bound on the joints the proposer may place.
    public var maximumJoints: Int = 6
    /// Percent stretch relied on along warp/weft. Both nil means geometry-only (no fabric adjustment).
    public var warpStretchPercent: Double?
    public var weftStretchPercent: Double?
    /// Skip seam solving on pieces above this many faces to keep runs bounded.
    public var maximumFacesForSeamSolve: Int = 30_000
    /// When set, the prepared mesh and every cut piece are written here as OBJ files.
    public var outputDirectory: URL?
    /// Taubin smoothing passes applied before orientation and cutting; 0 disables smoothing.
    public var smoothingIterations: Int = MeshSmoothing.defaultIterations

    public init() {}
}

public struct PlushAgentPiece: Codable, Sendable {
    public let index: Int
    public let label: String
    public let faces: Int
    public let areaShare: Double
    public let openings: Int
    public let seamPaths: [[Int]]?
    public let panelCount: Int?
    public let worstAreaDelta: Double?
    public let worstStitchLengthMismatch: Double?
    public let rationale: String?
    public let issue: String?
    public let advisory: String?
    public let file: String?
}

public struct PlushAgentJoint: Codable, Sendable {
    public let name: String
    public let position: [Double]
    public let direction: [Double]
    public let positiveLabel: String
    public let negativeLabel: String
}

public struct PlushAgentReport: Codable, Sendable {
    public var input: String
    public var originalVertices = 0
    public var originalFaces = 0
    public var finalVertices = 0
    public var finalFaces = 0
    public var budget = "ok"
    public var simplified = false
    public var orientationUp: [Double] = [0, 1, 0]
    public var orientationStable = false
    public var mirrorAxis: String?
    public var mirrorMatch: Double?
    public var joints: [PlushAgentJoint] = []
    public var pieces: [PlushAgentPiece] = []
    public var preparedMeshFile: String?
    public var steps: [String] = []
    public var warnings: [String] = []
    public var verdict = "failed"

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

public enum PlushAgentError: LocalizedError {
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason): "The agent could not load the mesh: \(reason)"
        }
    }
}

public enum PlushAgent {
    public static func run(input url: URL, options: PlushAgentOptions = PlushAgentOptions()) throws -> PlushAgentReport {
        var report = PlushAgentReport(input: url.lastPathComponent)

        // 1. Probe: load and validate.
        let imported: ImportedMesh
        do {
            imported = try OBJMeshReader.read(try Data(contentsOf: url))
        } catch {
            throw PlushAgentError.unreadable(error.localizedDescription)
        }
        var (positions, triangles) = imported.topologyInput
        report.originalVertices = positions.count
        report.originalFaces = triangles.count / 3
        report.steps.append("Loaded \(positions.count) vertices, \(triangles.count / 3) faces.")

        let loops = OpenPieceSeams.boundaryLoops(triangles: triangles).count
        report.steps.append(loops == 0 ? "Mesh is closed." : "Mesh has \(loops) open boundary loop(s).")

        // 2. Assess budget, simplify if needed.
        let budget = ModelPreparation.assess(vertexCount: positions.count, faceCount: triangles.count / 3)
        report.budget = switch budget.level {
        case .ok: "ok"
        case .large: "large"
        case .needsSimplification: "needsSimplification"
        }
        if let message = budget.message { report.steps.append(message) }
        if budget.level != .ok, triangles.count / 3 > options.targetFaces {
            let result = MeshSimplifier.simplify(positions: positions, triangles: triangles, targetFaces: options.targetFaces)
            let before = surfaceArea(positions: positions, triangles: triangles)
            let after = surfaceArea(positions: result.positions, triangles: result.triangles)
            positions = result.positions
            triangles = result.triangles
            report.simplified = result.collapses > 0
            report.steps.append("Simplified to \(positions.count) vertices, \(triangles.count / 3) faces (\(result.collapses) collapses, surface area drift \(percent(before > 0 ? abs(after - before) / before : 0))).")
            if triangles.count / 3 > options.targetFaces {
                report.warnings.append("Simplification stopped at \(triangles.count / 3) faces; the target of \(options.targetFaces) was not reached without breaking topology.")
            }
        }

        // Lumps in a scanned or generated surface are noise for a sewing pattern.
        if options.smoothingIterations > 0 {
            positions = MeshSmoothing.taubin(positions: positions, triangles: triangles, iterations: options.smoothingIterations)
            report.steps.append("Smoothed surface lumpiness (\(options.smoothingIterations) Taubin iterations).")
        }

        // 3. Orientation: rest on the steadiest face.
        if let best = ModelPreparation.orientationCandidates(positions: positions).first {
            positions = ModelPreparation.oriented(positions, up: best.up)
            report.orientationUp = [best.up.x, best.up.y, best.up.z]
            report.orientationStable = best.centerOfMassSupported
            report.steps.append("Oriented with \(describe(best.up)) up (\(best.centerOfMassSupported ? "stable" : "center of mass unsupported")).")
            if !best.centerOfMassSupported { report.warnings.append("No axis gives a stable resting pose; check orientation manually.") }
        }

        // 4. Symmetry.
        if let mirror = ModelPreparation.detectMirror(positions: positions) {
            report.mirrorAxis = ["x", "y", "z"][mirror.axis]
            report.mirrorMatch = mirror.matchedFraction
            report.steps.append("Mirror symmetry across \(report.mirrorAxis!) (\(percent(mirror.matchedFraction)) matched).")
        }

        report.finalVertices = positions.count
        report.finalFaces = triangles.count / 3
        let outputNames = try prepareOutput(options.outputDirectory)
        if let dir = options.outputDirectory {
            let file = "prepared.obj"
            try writeOBJ(positions: positions, triangles: triangles).write(to: dir.appendingPathComponent(file))
            report.preparedMeshFile = file
        }
        _ = outputNames

        // 5. Joints and cuts.
        let joints = JointProposer.propose(positions: positions, triangles: triangles, maximumJoints: options.maximumJoints)
        report.joints = joints.map {
            PlushAgentJoint(name: $0.name, position: [$0.position.x, $0.position.y, $0.position.z], direction: [$0.direction.x, $0.direction.y, $0.direction.z], positiveLabel: $0.positiveLabel, negativeLabel: $0.negativeLabel)
        }
        var components: [MeshComponent]
        if joints.isEmpty {
            report.steps.append("No joints found; treating the mesh as a single piece.")
            report.warnings.append("The proposer found no narrow cross-sections. Place joints manually if the model has limbs or a head.")
            components = [MeshComponent(id: 0, positions: positions, triangles: triangles, sourceVertices: Array(positions.indices), anatomicalLabel: "body")]
        } else {
            report.steps.append("Proposed \(joints.count) joint(s).")
            do {
                components = try StagedAnatomySplit.split(positions: positions, triangles: triangles, joints: joints)
                report.steps.append("Cut into \(components.count) piece(s).")
            } catch {
                report.warnings.append("Cutting at joints failed: \(error.localizedDescription). Falling back to a single piece.")
                components = [MeshComponent(id: 0, positions: positions, triangles: triangles, sourceVertices: Array(positions.indices), anatomicalLabel: "body")]
            }
        }

        // 6. Per-piece cut assessment and seam suggestion.
        let fabric: FabricProfile
        if let warp = options.warpStretchPercent, let weft = options.weftStretchPercent {
            fabric = .twoWayStretch(warpPercent: warp, weftPercent: weft)
        } else {
            fabric = .none
        }
        let totalArea = max(components.reduce(0) { $0 + $1.surfaceArea }, 1e-12)
        var failures = 0, softIssues = 0
        for component in components {
            let label = component.anatomicalLabel ?? "piece \(component.id + 1)"
            let openings = OpenPieceSeams.boundaryLoops(triangles: component.triangles).count
            var seams: [[Int]]?, panels: Int?, areaDelta: Double?, stitch: Double?, rationale: String?, issue: String?, advisory: String?
            if component.triangleCount > options.maximumFacesForSeamSolve {
                issue = "Too large to solve (\(component.triangleCount) faces)."
            } else {
                do {
                    if let best = try SeamSuggestionEngine.suggest(positions: component.positions, triangles: component.triangles, fabric: fabric, maximumSuggestions: 1).first {
                        seams = best.seamPaths.map { path in path.map { component.sourceVertices[$0] } }
                        panels = best.panelCount
                        areaDelta = best.worstAreaDelta
                        // The engine scores only the cuts it chose; the audit also covers cuts the flattener adds.
                        var audited = best.worstStitchLengthMismatch
                        if let flat = try? TopologyEngine.flatten(positions: component.positions, triangles: component.triangles, seams: best.seamPaths, fabric: fabric) {
                            audited = max(audited, StitchAudit.audit(flat.islands).worstMismatch)
                            panels = flat.islands.count
                        }
                        stitch = audited
                        rationale = best.rationale
                        if best.worstAreaDelta > 0.05 { issue = "Area delta \(percent(best.worstAreaDelta)) exceeds the 5% tolerance." }
                        else if audited > 0.15 { advisory = "Stitch edges differ by \(percent(audited)); ease or re-cut." }
                    } else {
                        issue = "No passing seam layout was found."
                    }
                } catch {
                    issue = "Seam suggestion failed: \(error.localizedDescription)"
                }
            }
            if issue != nil { failures += 1 } else if advisory != nil { softIssues += 1 }

            var file: String?
            if let dir = options.outputDirectory {
                let safe = label.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
                file = "piece_\(component.id + 1)_\(safe).obj"
                try writeOBJ(positions: component.positions, triangles: component.triangles).write(to: dir.appendingPathComponent(file!))
            }
            report.pieces.append(PlushAgentPiece(
                index: component.id, label: label, faces: component.triangleCount,
                areaShare: component.surfaceArea / totalArea, openings: openings,
                seamPaths: seams, panelCount: panels, worstAreaDelta: areaDelta,
                worstStitchLengthMismatch: stitch, rationale: rationale, issue: issue, advisory: advisory, file: file
            ))
        }
        if failures > 0 { report.warnings.append("\(failures) of \(components.count) piece(s) need attention.") }
        if softIssues > 0 { report.warnings.append("\(softIssues) piece(s) flatten within tolerance but have mismatched stitch edges.") }
        report.verdict = failures == components.count ? "failed" : (failures + softIssues == 0 ? "ready" : "needsAttention")
        return report
    }

    private static func prepareOutput(_ directory: URL?) throws -> Bool {
        guard let directory else { return false }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return true
    }

    private static func writeOBJ(positions: [Vec3], triangles: [Int32]) -> Data {
        var text = ""
        text.reserveCapacity(positions.count * 32 + triangles.count * 10)
        for p in positions { text += "v \(p.x) \(p.y) \(p.z)\n" }
        for t in stride(from: 0, to: triangles.count, by: 3) {
            text += "f \(triangles[t] + 1) \(triangles[t + 1] + 1) \(triangles[t + 2] + 1)\n"
        }
        return Data(text.utf8)
    }

    private static func surfaceArea(positions: [Vec3], triangles: [Int32]) -> Double {
        stride(from: 0, to: triangles.count, by: 3).reduce(0) { total, t in
            let a = positions[Int(triangles[t])], b = positions[Int(triangles[t + 1])], c = positions[Int(triangles[t + 2])]
            return total + 0.5 * vlength(vcross(b - a, c - a))
        }
    }

    private static func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }

    private static func describe(_ up: Vec3) -> String {
        let names = [(Vec3(1, 0, 0), "+X"), (Vec3(-1, 0, 0), "-X"), (Vec3(0, 1, 0), "+Y"), (Vec3(0, -1, 0), "-Y"), (Vec3(0, 0, 1), "+Z"), (Vec3(0, 0, -1), "-Z")]
        return names.first { vdot($0.0, up) > 0.99 }?.1 ?? "custom"
    }
}

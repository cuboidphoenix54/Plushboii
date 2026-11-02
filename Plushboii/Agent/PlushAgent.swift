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
    /// Maximum dart count used when solving rigid-fabric pieces. Nil keeps the geometry-only profile.
    public var rigidMaximumDarts: Int?
    /// Seam allowance for pattern files, in points (1/72 inch).
    public var seamAllowancePoints: Double = 18
    /// Skip seam solving on pieces above this many faces to keep runs bounded.
    public var maximumFacesForSeamSolve: Int = 30_000
    /// When set, the prepared mesh and every cut piece are written here as OBJ files.
    public var outputDirectory: URL?
    /// Taubin smoothing passes applied before orientation and cutting; 0 disables smoothing.
    public var smoothingIterations: Int = MeshSmoothing.defaultIterations

    /// Axis-aligned anatomical cuts (from the MLX model) used instead of joint proposals when set.
    var anatomyCuts: [AnatomicalCut]?

    /// JSON file with the user's corrections to the MLX anatomy plan (replacement cuts and/or visible regions).
    public var correctionsFile: URL?
    /// When set with corrections that replace the cuts, a fine-tuning example is saved here for the next MLX training run.
    public var learnDirectory: URL?
    /// Regions where seams would be conspicuous (derived from face labels and corrections).
    var visibility: SeamVisibility = .none

    /// Forces creature or object handling; `.auto` classifies from the geometry.
    public var subject: SubjectOverride = .auto

    /// Sections an object is divided into along its longest axis; nil lets the agent choose and escalate.
    var objectSlabs: Int?

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
    public var subjectKind = "creature"
    public var subjectScore = 0.0
    public var subjectReasons: [String] = []
    public var objectSlabs = 1
    public var construction: [String] = []
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
    /// The model is treated as a hollow fabric shell: the surface shape is preserved, the source pose is not.
    static func constructionNotes(kind: SubjectKind, components: [MeshComponent]) -> [String] {
        var notes = [
            "Hollow fabric shell stuffed with polyfill; the surface shape is preserved, the source pose is not.",
            "Each piece is flattened from its own surface, so pose, limb bend and orientation do not change the pattern."
        ]
        notes.append("Finishing: notch convex seam allowances and clip concave ones; mark quarter-point notches on long curved seams; sew a muslin toile before cutting pile fabric.")
        notes.append("Stuffing inflates the shell and softens sharp detail; use lightweight fusible interfacing on stretch knits (Minky) to hold the drafted proportions.")
        if kind == .creature, components.count > 1 {
            let limbs = components.compactMap(\.anatomicalLabel).filter { !$0.isEmpty && $0 != "body" && $0 != "torso" }
            notes.append("Teddy-bear articulation: sew limbs and head as separate stuffed pieces and attach them to the body at the cut openings (\(limbs.count) attachment(s)), so they can be posed freely.")
        }
        return notes
    }

    public static func run(input url: URL, options: PlushAgentOptions = PlushAgentOptions()) throws -> PlushAgentReport {
        var best = try runPass(input: url, options: options)
        guard best.subjectKind == SubjectKind.object.rawValue, options.objectSlabs == nil,
              !best.steps.contains(where: { $0.hasPrefix("Tapered") || $0.hasPrefix("Flat object") }) else { return best }
        // A single object surface rarely flattens within tolerance; divide it into more sections until every piece verifies.
        for slabs in [3, 4, 6, 8, 12] where slabs > best.objectSlabs && best.verdict != "ready" {
            var retry = options
            retry.objectSlabs = slabs
            let report = try runPass(input: url, options: retry)
            let failed = { (r: PlushAgentReport) in r.pieces.filter { $0.issue != nil }.count }
            if failed(report) <= failed(best) { best = report }
        }
        return best
    }

    private static func runPass(input url: URL, options: PlushAgentOptions) throws -> PlushAgentReport {
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
            // Plush pose is irrelevant: the stuffed result is rebuilt in a neutral pose, so an unstable scan pose is not a defect.
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
        let subject = SubjectClassifier.classify(
            positions: positions, triangles: triangles, joints: joints, mirrorMatch: report.mirrorMatch, override: options.subject
        )
        report.subjectKind = subject.kind.rawValue
        report.subjectScore = subject.creatureScore
        report.subjectReasons = subject.reasons
        report.steps.append("Subject: \(subject.kind.rawValue) (creature score \(String(format: "%.2f", subject.creatureScore))).")
        var components: [MeshComponent]
        if subject.kind == .object {
            // Objects need far less detail than a character; coarser meshes flatten and solve much faster.
            let objectFaces = min(options.targetFaces, 5_000)
            if triangles.count / 3 > objectFaces {
                let coarse = MeshSimplifier.simplify(positions: positions, triangles: triangles, targetFaces: objectFaces)
                positions = coarse.positions; triangles = coarse.triangles
                report.steps.append("Object simplified further to \(triangles.count / 3) faces.")
            }
            let whole = MeshComponent(id: 0, positions: positions, triangles: triangles, sourceVertices: Array(positions.indices), anatomicalLabel: "body")
            let slabs = subject.strategy == .frontBack || subject.strategy == .gores ? 2 : (options.objectSlabs ?? (HandleSeams.genus(triangles: triangles) > 0 ? 3 : 1))
            report.objectSlabs = slabs
            do {
                if subject.strategy == .gores, let axis = subject.taperAxis {
                    components = try SubjectClassifier.goreComponents(positions: positions, triangles: triangles, axis: axis, baseAtHigh: subject.baseAtHigh)
                    report.objectSlabs = 1
                    report.steps.append("Tapered object: circular base plus \(components.count - 1) leaves meeting at the apex; sew the leaves together, then set in the base.")
                    let guide = SubjectClassifier.goreGuidance(maxRadius: SubjectClassifier.goreDifferential(positions: positions, axis: axis, baseAtHigh: subject.baseAtHigh)?.maxRadius ?? 0, currentCount: max(components.count - 1, 1))
                    if guide.recommendedCount > components.count - 1 {
                        report.steps.append(String(format: "Gore width is %.2f units at the fullest point with %d leaves; %d gores (%.2f wide each) give a smoother stuffed dome. Re-cut with more gores for a rounder result.", guide.widthAtCurrent, components.count - 1, guide.recommendedCount, guide.widthAtRecommended))
                    }
                    if components.count == 5, let d = SubjectClassifier.goreDifferential(positions: positions, axis: axis, baseAtHigh: subject.baseAtHigh) {
                        report.steps.append(String(format: "Longer leaf pair (B) drafted %.1f%% longer (+%.2f units on a %.2f meridian; profile turns %.0f°). Pin B to A at quarter points and ease the difference evenly (no tucks) when sewing.", d.extraLength / d.meridianLength * 100, d.extraLength, d.meridianLength, d.turningAngle * 180 / .pi))
                    }
                } else if let cuts = SubjectClassifier.objectCuts(for: subject) {
                    components = try AnatomicalMeshSplitter.split(positions: positions, triangles: triangles, cuts: cuts)
                    report.steps.append("Flat object: split into front/back shells; sew them together around the rim.")
                } else if slabs > 1 {
                    components = try SubjectClassifier.slabComponents(positions: positions, triangles: triangles, count: slabs)
                    report.steps.append("Object: divided into \(components.count) sections along its longest axis; sew them end to end.")
                } else {
                    components = [whole]
                    report.steps.append("Object: no cuts; keeping one piece and letting the seam solver place seams.")
                }
            } catch {
                report.warnings.append("Object split failed: \(error.localizedDescription). Using a single piece.")
                components = [whole]
            }
        } else if let cuts = options.anatomyCuts {
            do {
                components = try StagedAnatomySplit.split(positions: positions, triangles: triangles, cuts: cuts)
                report.steps.append("Cut into \(components.count) piece(s) along \(cuts.count) MLX-proposed plane(s).")
            } catch {
                report.warnings.append("Cutting at MLX planes failed: \(error.localizedDescription). Falling back to a single piece.")
                components = [MeshComponent(id: 0, positions: positions, triangles: triangles, sourceVertices: Array(positions.indices), anatomicalLabel: "body")]
            }
        } else if joints.isEmpty {
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

        var seamVisibility = options.visibility
        if let file = options.correctionsFile, let correction = try? AnatomyCorrection.load(file) {
            seamVisibility.regions += (correction.visibleRegions ?? []).filter { !seamVisibility.regions.contains($0) }
        }
        report.construction = constructionNotes(kind: subject.kind, components: components) + SeamRules.generalRules
        if report.steps.contains(where: { $0.hasPrefix("Tapered") }) {
            report.construction.append("Teardrop/cone: mating seams between leaves must be equal length. Make the longer pair longer through a fuller curve profile, not a longer joining edge.")
        }
        if report.steps.contains(where: { $0.hasPrefix("Flat object") }) {
            report.construction.append("Flat-faced shapes bulge when stuffed: interface the flat panels or add a rigid insert, and use a gusset strip if you want a straight side wall.")
        }

        // 6. Per-piece cut assessment and seam suggestion.
        let fabric: FabricProfile
        if let maximumDarts = options.rigidMaximumDarts {
            fabric = .rigid(maxDarts: maximumDarts)
        } else if let warp = options.warpStretchPercent, let weft = options.weftStretchPercent {
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
                    if let best = try SeamSuggestionEngine.suggest(positions: component.positions, triangles: component.triangles, fabric: fabric, maximumSuggestions: 1, visibility: seamVisibility.bound(to: positions)).first {
                        seams = best.seamPaths.map { path in path.map { component.sourceVertices[$0] } }
                        if let dir = options.outputDirectory, options.anatomyCuts != nil || subject.kind == .object {
                            try JSONEncoder().encode(best.seamPaths).write(to: dir.appendingPathComponent("piece_\(component.id + 1)_seams.json"))
                        }
                        panels = best.panelCount
                        areaDelta = best.worstAreaDelta
                        // The engine scores only the cuts it chose; the audit also covers cuts the flattener adds.
                        var audited = best.worstStitchLengthMismatch
                        if let flat = try? TopologyEngine.flatten(positions: component.positions, triangles: component.triangles, seams: best.seamPaths, fabric: fabric) {
                            audited = max(audited, StitchAudit.audit(flat.islands).worstMismatch)
                            panels = flat.islands.count
                            let groups = PieceCongruence.groups(for: flat)
                            let u = SeamRules.uniformity(groups, pieceCount: flat.islands.count)
                            report.construction.append(String(format: "%@: %d panel(s), %.0f%% in identical/mirrored sets.", label, flat.islands.count, u * 100))
                            report.construction += SeamRules.cuttingNotes(groups: groups) { "\(label) panel \($0 + 1)" }
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

import Foundation

/// Seam allowances commonly used by plushie and soft-toy patterns.
enum SeamAllowanceOption: String, CaseIterable, Sendable, Identifiable {
    case sixMillimeters
    case quarterInch
    case threeEighthsInch
    case oneCentimeter
    case halfInch
    case fiveEighthsInch
    case oneAndHalfCentimeters

    var id: String { rawValue }

    static let standard = SeamAllowanceOption.quarterInch

    var points: Double {
        switch self {
        case .sixMillimeters: 0.6 / 2.54 * PatternUnits.pointsPerInch
        case .quarterInch: 0.25 * PatternUnits.pointsPerInch
        case .threeEighthsInch: 0.375 * PatternUnits.pointsPerInch
        case .oneCentimeter: 1.0 / 2.54 * PatternUnits.pointsPerInch
        case .halfInch: 0.5 * PatternUnits.pointsPerInch
        case .fiveEighthsInch: 0.625 * PatternUnits.pointsPerInch
        case .oneAndHalfCentimeters: 1.5 / 2.54 * PatternUnits.pointsPerInch
        }
    }

    var displayName: String {
        switch self {
        case .sixMillimeters: "6 mm"
        case .quarterInch: "1/4\" (6.4 mm)"
        case .threeEighthsInch: "3/8\" (9.5 mm)"
        case .oneCentimeter: "1 cm"
        case .halfInch: "1/2\" (12.7 mm)"
        case .fiveEighthsInch: "5/8\" (15.9 mm)"
        case .oneAndHalfCentimeters: "1.5 cm"
        }
    }

    var usage: String {
        switch self {
        case .sixMillimeters: "Minky and tight curves"
        case .quarterInch: "Standard plushie default"
        case .threeEighthsInch: "Stretchy or fraying fabrics"
        case .oneCentimeter: "Metric patterns"
        case .halfInch: "Loosely woven fabrics"
        case .fiveEighthsInch: "Dressmaking standard"
        case .oneAndHalfCentimeters: "Metric dressmaking"
        }
    }
}

enum FabricStretch: String, CaseIterable, Sendable {
    case woven
    case stretchKnit

    var toleranceScale: Double { self == .stretchKnit ? 1.5 : 1 }
}

/// Seam-allowance geometry on a curved edge: offsetting a convex curve outward by `a` lengthens it by `a * turning`
/// (arc length scales with radius), so convex edges need notches to lie flat once turned; concave edges shorten by the
/// same amount and need clips.
struct AllowanceCurvature: Sendable, Equatable {
    /// Total turning (radians) of convex and concave corners along the closed outline, measured against its winding.
    let convexTurning: Double
    let concaveTurning: Double

    func excessCentimeters(allowanceCentimeters a: Double) -> Double { convexTurning * a }

    /// One notch or clip per 15 degrees of turning keeps each wedge under about 1 mm at a 6 mm allowance.
    static let degreesPerCut = 15.0
    var notchCount: Int { Int((convexTurning * 180 / .pi / Self.degreesPerCut - 1e-9).rounded(.up)) }
    var clipCount: Int { Int((concaveTurning * 180 / .pi / Self.degreesPerCut - 1e-9).rounded(.up)) }

    static func measure(outline: [Vec2]) -> AllowanceCurvature {
        let n = outline.count
        guard n >= 3 else { return AllowanceCurvature(convexTurning: 0, concaveTurning: 0) }
        var area2 = 0.0
        for i in 0..<n {
            let a = outline[i], b = outline[(i + 1) % n]
            area2 += a.x * b.y - b.x * a.y
        }
        let winding = area2 >= 0 ? 1.0 : -1.0
        var convex = 0.0, concave = 0.0
        for i in 0..<n {
            let a = outline[(i + n - 1) % n], b = outline[i], c = outline[(i + 1) % n]
            let u = b - a, v = c - b
            guard vlength(u) > 1e-12, vlength(v) > 1e-12 else { continue }
            let turn = atan2(u.x * v.y - u.y * v.x, u.x * v.x + u.y * v.y) * winding
            if turn >= 0 { convex += turn } else { concave -= turn }
        }
        return AllowanceCurvature(convexTurning: convex, concaveTurning: concave)
    }
}

enum JoinTechnique: String, Sendable, Equatable {
    case match = "Match edges"
    case ease = "Ease"
    case gather = "Gather"
    case recut = "Re-cut"
}

/// How one seam between two pieces should be sewn, from the lengths of the two edges.
struct JoinNote: Sendable, Equatable {
    let partner: Int
    let lengthCentimeters: Double
    let partnerLengthCentimeters: Double
    /// Fractional extra length of the longer edge relative to the shorter one.
    let mismatch: Double
    /// True when this piece carries the longer edge (the one to ease or gather).
    let isLongerSide: Bool
    let technique: JoinTechnique

    /// Woven: up to 3% matches, 10% eases, 30% gathers. Stretch knits (Minky, fleece) absorb about 1.5x more per step
    /// because the fabric itself gives 30-50%. Anything beyond is flagged for a re-cut.
    static func technique(forMismatch mismatch: Double, fabric: FabricStretch = .woven) -> JoinTechnique {
        let k = fabric.toleranceScale
        if mismatch <= 0.03 * k { return .match }
        if mismatch <= 0.10 * k { return .ease }
        if mismatch <= 0.30 * k { return .gather }
        return .recut
    }
}

/// A flattened dart: the wedge to fold out and stitch closed so the flat panel takes the curved shape.
struct DartNote: Sendable, Equatable {
    let depthCentimeters: Double
    let widthCentimeters: Double
    let angleDegrees: Double
    /// Apex position in island UV units.
    let apexUV: Vec2
}

struct PieceSewingNotes: Sendable, Equatable {
    var joins: [JoinNote] = []
    var darts: [DartNote] = []
    var curvature = AllowanceCurvature(convexTurning: 0, concaveTurning: 0)

    var summaryLines: [String] {
        var lines: [String] = darts.enumerated().map { index, dart in
            String(format: "Dart %d: %.1f cm deep, %.1f cm wide at the mouth", index + 1, dart.depthCentimeters, dart.widthCentimeters)
        }
        for join in joins where join.technique != .match {
            let verb = join.isLongerSide ? "\(join.technique.rawValue) this edge" : "Partner edge is longer"
            lines.append(String(format: "%@ (+%.0f%%) with piece %d", verb, join.mismatch * 100, join.partner + 1))
        }
        if curvature.notchCount > 0 || curvature.clipCount > 0 {
            lines.append("Seam allowance: notch ~\(curvature.notchCount) convex, clip ~\(curvature.clipCount) concave")
        }
        return lines
    }
}

enum SewingGuide {
    /// Per-island notes in island order. Partners are island indices, as in `SeamSections`.
    static func notes(for result: FlatteningResult, centimetersPerUnit: Double, fabric: FabricStretch = .woven) -> [PieceSewingNotes] {
        guard centimetersPerUnit.isFinite, centimetersPerUnit > 0 else {
            return result.islands.map { _ in PieceSewingNotes() }
        }
        let sections = SeamSections.sections(for: result)
        let loops: [[Int32]?] = result.islands.map { try? PatternGeometry.boundaryIndices(of: $0) }

        func length(of section: SeamSection, island: UVIsland, loop: [Int32]) -> Double {
            var total = 0.0
            for k in section.start..<(section.start + section.count) {
                let a = island.uv[Int(loop[k % loop.count])]
                let b = island.uv[Int(loop[(k + 1) % loop.count])]
                total += vlength(b - a)
            }
            return total * centimetersPerUnit
        }

        var lengths: [Int: [Int: Double]] = [:]
        for index in result.islands.indices {
            guard let loop = loops[index], index < sections.count else { continue }
            for section in sections[index] {
                guard let partner = section.partner, partner != index else { continue }
                lengths[index, default: [:]][partner, default: 0] += length(of: section, island: result.islands[index], loop: loop)
            }
        }

        return result.islands.indices.map { index in
            var notes = PieceSewingNotes()
            for (partner, mine) in (lengths[index] ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let theirs = lengths[partner]?[index], mine > 1e-9, theirs > 1e-9 else { continue }
                let mismatch = max(mine, theirs) / min(mine, theirs) - 1
                notes.joins.append(JoinNote(
                    partner: partner,
                    lengthCentimeters: mine,
                    partnerLengthCentimeters: theirs,
                    mismatch: mismatch,
                    isLongerSide: mine >= theirs,
                    technique: JoinNote.technique(forMismatch: mismatch, fabric: fabric)
                ))
            }
            let island = result.islands[index]
            if let loop = loops[index] {
                notes.curvature = AllowanceCurvature.measure(outline: loop.map { island.uv[Int($0)] })
            }
            for dart in island.darts {
                guard let apex = island.sourceVertex.firstIndex(of: dart.apexVertex) else { continue }
                notes.darts.append(DartNote(
                    depthCentimeters: dart.legLength * centimetersPerUnit,
                    widthCentimeters: dart.mouthWidth * centimetersPerUnit,
                    angleDegrees: dart.openingAngle * 180 / .pi,
                    apexUV: island.uv[apex]
                ))
            }
            return notes
        }
    }
}

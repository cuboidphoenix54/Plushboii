import Foundation

enum SubjectKind: String, Codable, Sendable {
    case creature
    case object
}

public enum SubjectOverride: String, Codable, Sendable {
    case auto, creature, object
}

enum ObjectStrategy: String, Codable, Sendable {
    /// Thin shapes such as masks or plaques: a front shell and a back shell joined around the rim.
    case frontBack
    /// Teardrops, cones and obelisks: a circular base plus four leaves (gores) meeting at the apex.
    case gores
    /// Compact or elongated shapes such as a drill or a mug: one piece, seams placed by the solver.
    case singlePiece
    /// Boxes, pyramids and other flat-faced solids: one panel per face.
    case facets
    /// Cylinders and truncated cones: a side band between two flat end caps.
    case tube
    /// Spheres, spheroids, capsules and other solids of revolution: identical pole-to-pole gores.
    case meridianGores
}

struct SubjectAnalysis: Codable, Equatable, Sendable {
    let kind: SubjectKind
    /// 0 (clearly an object) ... 1 (clearly a creature).
    let creatureScore: Double
    let jointCount: Int
    let thickness: Double
    let mirrorMatch: Double?
    let strategy: ObjectStrategy?
    let thinAxis: AnatomicalAxis?
    let taperAxis: AnatomicalAxis?
    let baseAtHigh: Bool
    let reasons: [String]
    let forced: Bool
    var primitive: PrimitiveFit? = nil
}

enum SubjectClassifier {
    /// Smallest-to-largest bounding extent ratio below which a shape is treated as flat.
    static let flatThreshold = 0.25
    static let creatureThreshold = 0.5

    /// Geometry-only classification. Creatures show several narrow necks (head, limbs, tail) that the joint
    /// proposer can find; objects show none or one, and flat objects such as masks are very thin.
    static func classify(
        positions: [Vec3],
        triangles: [Int32],
        joints: [AnatomicalJoint],
        mirrorMatch: Double?,
        override: SubjectOverride = .auto,
        sharpPositions: [Vec3]? = nil
    ) -> SubjectAnalysis {
        var low = positions.first ?? Vec3(0, 0, 0), high = low
        for p in positions {
            low = Vec3(min(low.x, p.x), min(low.y, p.y), min(low.z, p.z))
            high = Vec3(max(high.x, p.x), max(high.y, p.y), max(high.z, p.z))
        }
        let extents = [(AnatomicalAxis.x, high.x - low.x), (.y, high.y - low.y), (.z, high.z - low.z)]
        let longest = extents.map(\.1).max() ?? 0
        let thinnest = extents.min { $0.1 < $1.1 }
        let thickness = longest > 0 ? (thinnest?.1 ?? 0) / longest : 0
        let isFlat = thickness < flatThreshold

        var score = 0.3 * Double(min(joints.count, 3))
        var reasons: [String] = []
        reasons.append(joints.isEmpty ? "No narrow necks or limb joints found." : "\(joints.count) narrow joint(s) found (\(joints.map(\.name).joined(separator: ", "))).")
        if let mirrorMatch, mirrorMatch >= 0.85, !joints.isEmpty {
            score += 0.1
            reasons.append(String(format: "Bilateral symmetry %.0f%% alongside appendages.", mirrorMatch * 100))
        }
        if isFlat {
            score -= 0.35
            reasons.append(String(format: "Flat shape (thinnest extent is %.0f%% of the longest).", thickness * 100))
        }
        score = min(max(score, 0), 1)

        let detected: SubjectKind = score >= creatureThreshold ? .creature : .object
        let kind: SubjectKind
        switch override {
        case .auto: kind = detected
        case .creature: kind = .creature
        case .object: kind = .object
        }
        let forced = override != .auto
        if forced { reasons.append("Subject forced to \(kind.rawValue) by the user (detected: \(detected.rawValue)).") }

        let primitive = kind == .object && !isFlat ? PrimitiveDetector.detect(positions: sharpPositions ?? positions, triangles: triangles) : nil
        var taper = isFlat ? nil : taperProfile(positions: positions)
        var strategy: ObjectStrategy? = kind == .object ? (isFlat ? .frontBack : (taper != nil ? .gores : .singlePiece)) : nil
        if let primitive, kind == .object {
            reasons.append(primitive.summary)
            switch primitive.kind {
            case .box, .pyramid, .polyhedron: strategy = .facets; taper = nil
            case .cylinder, .frustum: strategy = .tube; taper = nil
            case .cone, .taperedRevolve: strategy = .gores; taper = (.y, primitive.baseAtHigh)
            case .sphere, .spheroid, .capsule, .revolve: strategy = .meridianGores; taper = nil
            }
        }
        if strategy == .gores { reasons.append("Tapers to an apex: base plus four leaves.") }
        return SubjectAnalysis(
            kind: kind,
            creatureScore: score,
            jointCount: joints.count,
            thickness: thickness,
            mirrorMatch: mirrorMatch,
            strategy: strategy,
            thinAxis: isFlat ? thinnest?.0 : nil,
            taperAxis: strategy == .gores ? taper?.axis : nil,
            baseAtHigh: taper?.baseAtHigh ?? false,
            reasons: reasons,
            forced: forced,
            primitive: primitive
        )
    }

    /// Cuts that turn an object into pieces. Creatures use anatomical cuts instead; this returns nil when
    /// the object should stay a single piece.
    static func objectCuts(for analysis: SubjectAnalysis) -> [AnatomicalCut]? {
        guard analysis.kind == .object, analysis.strategy == .frontBack, let axis = analysis.thinAxis else { return nil }
        return [AnatomicalCut(
            axis: axis,
            normalizedPosition: 0.5,
            boundary: "rim of the flat object",
            negativeRegion: "Back shell",
            positiveRegion: "Front shell",
            confidence: 1
        )]
    }

    /// A shape tapers when its cross-section shrinks steadily along its longest axis to a small tip.
    static func taperProfile(positions: [Vec3]) -> (axis: AnatomicalAxis, baseAtHigh: Bool)? {
        guard positions.count > 20, let first = positions.first else { return nil }
        var low = first, high = first
        for p in positions {
            low = Vec3(min(low.x, p.x), min(low.y, p.y), min(low.z, p.z))
            high = Vec3(max(high.x, p.x), max(high.y, p.y), max(high.z, p.z))
        }
        let size = high - low
        let axis: AnatomicalAxis = size.x >= size.y && size.x >= size.z ? .x : (size.y >= size.z ? .y : .z)
        let start = axis.coordinate(of: low), span = axis.coordinate(of: high) - start
        guard span > 0 else { return nil }
        let others = AnatomicalAxis.allCases.filter { $0 != axis }
        let bins = 8
        var radius = [Double](repeating: 0, count: bins)
        let centre = (low + high) * 0.5
        for p in positions {
            let b = min(bins - 1, Int((axis.coordinate(of: p) - start) / span * Double(bins)))
            let d = others.map { $0.coordinate(of: p) - $0.coordinate(of: centre) }
            radius[b] = max(radius[b], (d[0] * d[0] + d[1] * d[1]).squareRoot())
        }
        for baseAtHigh in [false, true] {
            let r = baseAtHigh ? Array(radius.reversed()) : radius
            let monotone = zip(r, r.dropFirst()).allSatisfy { $1 <= $0 * 1.15 }
            if monotone, r[0] > 0, r[bins - 1] < 0.4 * r[0], r[0] * 2 > 0.15 * span { return (axis, baseAtHigh) }
        }
        return nil
    }

    struct GoreDifferential: Sendable, Equatable {
        let meridianLength: Double
        let turningAngle: Double
        let meanRadius: Double
        let maxRadius: Double
        let extraLength: Double
        var factor: Double { meridianLength > 0 ? 1 + extraLength / meridianLength : 1 }
    }

    /// Gore width W = C / n at the fullest circumference C = 2 pi r. Four panels is only adequate when each is narrow;
    /// guidance is 6-8 gores for a smooth dome, so n grows until W is within one-sixth of the radius spread.
    static func goreGuidance(maxRadius: Double, currentCount: Int = 4) -> (widthAtCurrent: Double, recommendedCount: Int, widthAtRecommended: Double) {
        let c = 2 * Double.pi * max(maxRadius, 0)
        let recommended = maxRadius > 0 ? min(8, max(currentCount, 6)) : currentCount
        return (c / Double(max(currentCount, 1)), recommended, c / Double(max(recommended, 1)))
    }

    static let goreStuffingFloor = 0.02
    static let goreMaximumExtra = 0.12

    /// Differential panel logic: the outer-fibre of a curved profile is longer than the inner by (turning angle x offset).
    /// The profile r(z) is sampled in bins; its arc length L and total turning angle theta come from segment headings.
    /// The longer pair sits half a mean radius off the neutral axis, so extra = theta * r / 2, clamped to a 2% stuffing
    /// take-up floor and a 12% ceiling that gathering/easing can still absorb.
    static func goreDifferential(positions: [Vec3], axis: AnatomicalAxis, baseAtHigh: Bool) -> GoreDifferential? {
        guard positions.count > 8 else { return nil }
        let coords = positions.map { axis.coordinate(of: $0) }
        guard let lo = coords.min(), let hi = coords.max(), hi > lo else { return nil }
        let others = AnatomicalAxis.allCases.filter { $0 != axis }
        let centre = positions.reduce(Vec3(0, 0, 0), +) / Double(positions.count)
        let bins = 12
        var sum = [Double](repeating: 0, count: bins), count = [Int](repeating: 0, count: bins)
        for (i, p) in positions.enumerated() {
            let b = min(bins - 1, Int((coords[i] - lo) / (hi - lo) * Double(bins)))
            let d = others.map { $0.coordinate(of: p) - $0.coordinate(of: centre) }
            sum[b] += (d[0] * d[0] + d[1] * d[1]).squareRoot(); count[b] += 1
        }
        var profile: [(z: Double, r: Double)] = []
        for b in 0..<bins where count[b] > 0 {
            profile.append((lo + (hi - lo) * (Double(b) + 0.5) / Double(bins), sum[b] / Double(count[b])))
        }
        if baseAtHigh { profile.reverse() }
        guard profile.count >= 3 else { return nil }
        var length = 0.0, turning = 0.0, previousHeading: Double?
        for (a, b) in zip(profile, profile.dropFirst()) {
            let dz = abs(b.z - a.z), dr = b.r - a.r
            length += (dz * dz + dr * dr).squareRoot()
            let heading = atan2(dr, dz)
            if let previous = previousHeading { turning += abs(heading - previous) }
            previousHeading = heading
        }
        guard length > 0 else { return nil }
        let meanRadius = profile.map(\.r).reduce(0, +) / Double(profile.count)
        let raw = turning * meanRadius / 2
        let extra = min(max(raw, length * goreStuffingFloor), length * goreMaximumExtra)
        return GoreDifferential(meridianLength: length, turningAngle: turning, meanRadius: meanRadius, maxRadius: profile.map(\.r).max() ?? meanRadius, extraLength: extra)
    }

    /// Circular base plus four leaves. Leaves are named around the axis: the first adjacent pair is one mirrored
    /// pair and the second adjacent pair is the slightly longer pair.
    static func goreComponents(positions: [Vec3], triangles: [Int32], axis: AnatomicalAxis, baseAtHigh: Bool) throws -> [MeshComponent] {
        let whole = MeshComponent(id: 0, positions: positions, triangles: triangles, sourceVertices: Array(positions.indices), anatomicalLabel: nil)
        let coords = positions.map { axis.coordinate(of: $0) }
        guard let lo = coords.min(), let hi = coords.max(), hi > lo else { return [whole] }
        let capPosition = baseAtHigh ? 0.93 : 0.07
        let capCut = AnatomicalCut(axis: axis, normalizedPosition: capPosition, boundary: "base seam", negativeRegion: baseAtHigh ? "Leaf" : "Base", positiveRegion: baseAtHigh ? "Base" : "Leaf", confidence: 1)
        let parts = try AnatomicalMeshSplitter.split(positions: positions, triangles: triangles, cuts: [capCut])
        let plane = lo + (hi - lo) * capPosition
        func mean(_ part: MeshComponent) -> Double { part.positions.map { axis.coordinate(of: $0) }.reduce(0, +) / Double(max(part.positions.count, 1)) }
        let baseParts = parts.filter { baseAtHigh ? mean($0) >= plane : mean($0) < plane }
        guard let body = parts.filter({ baseAtHigh ? mean($0) < plane : mean($0) >= plane }).max(by: { $0.surfaceArea < $1.surfaceArea }), !baseParts.isEmpty else { return [whole] }

        let others = AnatomicalAxis.allCases.filter { $0 != axis }
        let centre = body.positions.reduce(Vec3(0, 0, 0), +) / Double(max(body.positions.count, 1))
        let cuts: [AnatomicalCut] = others.compactMap { other in
            let values = body.positions.map { other.coordinate(of: $0) }
            guard let l = values.min(), let h = values.max(), h > l else { return nil }
            return AnatomicalCut(axis: other, normalizedPosition: (other.coordinate(of: centre) - l) / (h - l), boundary: "leaf seam", negativeRegion: "Leaf", positiveRegion: "Leaf", confidence: 1)
        }
        guard cuts.count == 2 else { return [whole] }
        let leaves = try AnatomicalMeshSplitter.split(positions: body.positions, triangles: body.triangles, cuts: cuts)
        func angle(_ part: MeshComponent) -> Double {
            let c = part.positions.reduce(Vec3(0, 0, 0), +) / Double(max(part.positions.count, 1))
            return atan2(others[1].coordinate(of: c) - others[1].coordinate(of: centre), others[0].coordinate(of: c) - others[0].coordinate(of: centre))
        }
        let ordered = leaves.sorted { angle($0) < angle($1) }
        let differential = goreDifferential(positions: body.positions, axis: axis, baseAtHigh: baseAtHigh)
        func lengthened(_ leaf: MeshComponent) -> [Vec3] {
            guard let factor = differential?.factor else { return leaf.positions }
            return leaf.positions.map { p in
                let c = axis.coordinate(of: p)
                return p + axisVector(axis) * ((c - plane) * (factor - 1))
            }
        }
        var result: [MeshComponent] = []
        for part in baseParts {
            result.append(MeshComponent(id: 0, positions: part.positions, triangles: part.triangles, sourceVertices: part.sourceVertices, anatomicalLabel: "Base"))
        }
        for (i, leaf) in ordered.enumerated() {
            let label = ordered.count == 4 ? (i < 2 ? "Leaf A\(i + 1) (mirrored pair)" : "Leaf B\(i - 1) (longer pair)") : "Leaf \(i + 1)"
            let isLonger = ordered.count == 4 && i >= 2
            result.append(MeshComponent(id: 0, positions: isLonger ? lengthened(leaf) : leaf.positions, triangles: leaf.triangles, sourceVertices: leaf.sourceVertices.map { $0 >= 0 ? body.sourceVertices[$0] : -1 }, anatomicalLabel: label))
        }
        return result.enumerated().map { MeshComponent(id: $0.offset, positions: $0.element.positions, triangles: $0.element.triangles, sourceVertices: $0.element.sourceVertices, anatomicalLabel: $0.element.anatomicalLabel) }
    }

    private static func axisVector(_ axis: AnatomicalAxis) -> Vec3 {
        switch axis { case .x: return Vec3(1, 0, 0); case .y: return Vec3(0, 1, 0); case .z: return Vec3(0, 0, 1) }
    }

    /// Divides a mesh into `count` sections along its longest axis, peeling one off the low end at a time.
    static func slabComponents(positions: [Vec3], triangles: [Int32], count: Int) throws -> [MeshComponent] {
        var remaining = MeshComponent(id: 0, positions: positions, triangles: triangles, sourceVertices: Array(positions.indices), anatomicalLabel: nil)
        guard count > 1, let first = positions.first else { return [remaining] }
        var low = first, high = first
        for p in positions {
            low = Vec3(min(low.x, p.x), min(low.y, p.y), min(low.z, p.z))
            high = Vec3(max(high.x, p.x), max(high.y, p.y), max(high.z, p.z))
        }
        let size = high - low
        let axis: AnatomicalAxis = size.x >= size.y && size.x >= size.z ? .x : (size.y >= size.z ? .y : .z)
        let start = axis.coordinate(of: low), span = axis.coordinate(of: high) - start
        var sections: [MeshComponent] = []
        for i in 1..<count {
            let plane = start + span * Double(i) / Double(count)
            let ends = remaining.positions.map { axis.coordinate(of: $0) }
            guard let lo = ends.min(), let hi = ends.max(), hi > lo else { break }
            let cut = AnatomicalCut(
                axis: axis, normalizedPosition: (plane - lo) / (hi - lo), boundary: "section \(i) seam",
                negativeRegion: "Section \(i)", positiveRegion: "Section \(i + 1)", confidence: 1
            )
            let parts = try AnatomicalMeshSplitter.split(positions: remaining.positions, triangles: remaining.triangles, cuts: [cut])
            func mean(_ part: MeshComponent) -> Double { part.positions.map { axis.coordinate(of: $0) }.reduce(0, +) / Double(max(part.positions.count, 1)) }
            let below = parts.filter { mean($0) < plane }
            let above = parts.filter { mean($0) >= plane }
            guard let next = above.max(by: { $0.surfaceArea < $1.surfaceArea }), !below.isEmpty else { break }
            func remap(_ part: MeshComponent, label: String?) -> MeshComponent {
                MeshComponent(id: 0, positions: part.positions, triangles: part.triangles,
                              sourceVertices: part.sourceVertices.map { $0 >= 0 ? remaining.sourceVertices[$0] : -1 }, anatomicalLabel: label)
            }
            for part in below { sections.append(remap(part, label: "Section \(sections.count + 1)")) }
            for part in above where part.id != next.id { sections.append(remap(part, label: "Section \(sections.count + 1)")) }
            remaining = remap(next, label: nil)
        }
        sections.append(MeshComponent(id: 0, positions: remaining.positions, triangles: remaining.triangles, sourceVertices: remaining.sourceVertices, anatomicalLabel: "Section \(sections.count + 1)"))
        return sections.enumerated().map {
            MeshComponent(id: $0.offset, positions: $0.element.positions, triangles: $0.element.triangles, sourceVertices: $0.element.sourceVertices, anatomicalLabel: $0.element.anatomicalLabel)
        }
    }
}

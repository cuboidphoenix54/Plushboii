import Foundation

/// Applies anatomical cuts in stages so a limb cut cannot also slice the head, then halves any
/// piece left with several openings (a torso) into front and back panels.
enum StagedAnatomySplit {
    static let tubularLoopCount = 3

    static func split(positions: [Vec3], triangles: [Int32], cuts: [AnatomicalCut]) throws -> [MeshComponent] {
        var pieces: [MeshComponent]
        if cuts.count > 1, let staged = try? stagedPieces(positions: positions, triangles: triangles, cuts: cuts) {
            pieces = staged
        } else {
            pieces = try AnatomicalMeshSplitter.split(positions: positions, triangles: triangles, cuts: cuts)
        }

        return finish(pieces)
    }

    /// Splits at user-placed or proposed joints, then halves any multi-opening piece.
    static func split(positions: [Vec3], triangles: [Int32], joints: [AnatomicalJoint]) throws -> [MeshComponent] {
        finish(try AnatomicalMeshSplitter.split(positions: positions, triangles: triangles, joints: joints))
    }

    private static func finish(_ pieces: [MeshComponent]) -> [MeshComponent] {
        let all = pieces.flatMap(\.positions)
        let up = ModelPreparation.orientationCandidates(positions: all).first?.up ?? Vec3(0, 1, 0)
        var result: [MeshComponent] = []
        for original in pieces {
            var piece = original
            var feet: [MeshComponent] = []
            if OpenPieceSeams.boundaryLoops(triangles: piece.triangles).count >= tubularLoopCount,
               let joint = AnatomyNaming.footJoint(piece: piece, up: up),
               let parts = try? AnatomicalMeshSplitter.split(positions: piece.positions, triangles: piece.triangles, joints: [joint]),
               parts.count >= 3, let body = parts.max(by: { $0.surfaceArea < $1.surfaceArea }) {
                piece = body
                feet = parts.filter { $0.id != body.id }
            }
            result.append(contentsOf: feet)
            if OpenPieceSeams.boundaryLoops(triangles: piece.triangles).count >= tubularLoopCount,
               let halves = try? bisect(piece) {
                result.append(contentsOf: halves)
            } else {
                result.append(piece)
            }
        }
        let named = AnatomyNaming.name(result, up: up)
        return named.enumerated().map { index, piece in
            MeshComponent(id: index, positions: piece.positions, triangles: piece.triangles, sourceVertices: piece.sourceVertices, anatomicalLabel: piece.anatomicalLabel)
        }
    }

    private static func stagedPieces(positions: [Vec3], triangles: [Int32], cuts: [AnatomicalCut]) throws -> [MeshComponent] {
        let first = try AnatomicalMeshSplitter.split(positions: positions, triangles: triangles, cuts: [cuts[0]])
        guard let body = first.max(by: { $0.surfaceArea < $1.surfaceArea }) else {
            throw FlatteningError.invalidMesh("the neck cut produced no pieces")
        }
        let remapped = cuts.dropFirst().compactMap { cut -> AnatomicalCut? in
            let source = positions.map { cut.axis.coordinate(of: $0) }
            let local = body.positions.map { cut.axis.coordinate(of: $0) }
            guard let lo = source.min(), let hi = source.max(), let bodyLo = local.min(), let bodyHi = local.max(), bodyHi > bodyLo else { return nil }
            let plane = lo + (hi - lo) * cut.normalizedPosition
            let position = (plane - bodyLo) / (bodyHi - bodyLo)
            guard position > 0, position < 1 else { return nil }
            return AnatomicalCut(axis: cut.axis, normalizedPosition: position, boundary: cut.boundary, negativeRegion: cut.negativeRegion, positiveRegion: cut.positiveRegion, confidence: cut.confidence)
        }
        guard !remapped.isEmpty else { throw FlatteningError.invalidMesh("no later cut crosses the body piece") }
        let bodyPieces = try AnatomicalMeshSplitter.split(positions: body.positions, triangles: body.triangles, cuts: remapped)
        return first.filter { $0.id != body.id } + bodyPieces
    }

    /// Cuts through the middle of the piece's thinnest axis: the classic two-panel plush construction.
    private static func bisect(_ piece: MeshComponent) throws -> [MeshComponent] {
        let extents = AnatomicalAxis.allCases.map { axis -> (AnatomicalAxis, Double) in
            let values = piece.positions.map { axis.coordinate(of: $0) }
            return (axis, (values.max() ?? 0) - (values.min() ?? 0))
        }
        guard let thinnest = extents.min(by: { $0.1 < $1.1 }), thinnest.1 > 0 else {
            throw FlatteningError.invalidMesh("the piece has no extent to bisect")
        }
        let label = piece.anatomicalLabel ?? "body"
        let cut = AnatomicalCut(axis: thinnest.0, normalizedPosition: 0.5, boundary: "\(label) side seam", negativeRegion: "\(label) back", positiveRegion: "\(label) front", confidence: 0.8)
        return try AnatomicalMeshSplitter.split(positions: piece.positions, triangles: piece.triangles, cuts: [cut])
    }
}

/// Finds feet and gives every piece a plain anatomical name (Head, Torso front, Left Arm, Right Leg...).
/// Left and right are the character's own, assuming it faces the positive horizontal axis that is not its widest.
enum AnatomyNaming {
    /// A cut just below where two or more separate tips (feet) merge into the body, measured along `up`.
    static func footJoint(piece: MeshComponent, up: Vec3) -> AnatomicalJoint? {
        let heights = piece.positions.map { vdot($0, up) }
        guard let lo = heights.min(), let hi = heights.max(), hi > lo else { return nil }
        let triangleCount = piece.triangles.count / 3
        guard triangleCount > 0 else { return nil }
        var areas = [Double](repeating: 0, count: triangleCount)
        var centers = [Double](repeating: 0, count: triangleCount)
        var total = 0.0
        for t in 0..<triangleCount {
            let a = Int(piece.triangles[3 * t]), b = Int(piece.triangles[3 * t + 1]), c = Int(piece.triangles[3 * t + 2])
            areas[t] = 0.5 * vlength(vcross(piece.positions[b] - piece.positions[a], piece.positions[c] - piece.positions[a]))
            centers[t] = (heights[a] + heights[b] + heights[c]) / 3
            total += areas[t]
        }
        guard total > 0 else { return nil }

        var lastSplit: Double?
        var seenSplit = false
        for step in 1...20 {
            let level = lo + (hi - lo) * 0.02 * Double(step)
            let count = tipCount(piece: piece, areas: areas, centers: centers, level: level, minimumArea: total * 0.03)
            if count >= 2 { lastSplit = level; seenSplit = true } else if seenSplit { break }
        }
        guard let level = lastSplit else { return nil }
        let position = up * level
        return AnatomicalJoint(name: "feet", position: position, direction: up, positiveLabel: "", negativeLabel: "foot")
    }

    private static func tipCount(piece: MeshComponent, areas: [Double], centers: [Double], level: Double, minimumArea: Double) -> Int {
        var parent = Array(piece.positions.indices)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        var included: [Int] = []
        for t in 0..<areas.count where centers[t] < level {
            included.append(t)
            let a = Int(piece.triangles[3 * t]), b = Int(piece.triangles[3 * t + 1]), c = Int(piece.triangles[3 * t + 2])
            parent[find(b)] = find(a)
            parent[find(c)] = find(a)
        }
        var areaByRoot: [Int: Double] = [:]
        for t in included { areaByRoot[find(Int(piece.triangles[3 * t])), default: 0] += areas[t] }
        return areaByRoot.values.filter { $0 >= minimumArea }.count
    }

    static func name(_ pieces: [MeshComponent], up: Vec3) -> [MeshComponent] {
        guard pieces.count >= 2 else { return pieces }
        let all = pieces.flatMap(\.positions)
        let upUnit = up / vlength(up)
        let heights = all.map { vdot($0, upUnit) }
        guard let lo = heights.min(), let hi = heights.max(), hi > lo else { return pieces }

        let horizontal: [Vec3] = [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)].filter { abs(vdot($0, upUnit)) < 0.5 }
        guard horizontal.count == 2 else { return pieces }
        let spans = horizontal.map { axis -> Double in
            let v = all.map { vdot($0, axis) }
            return (v.max() ?? 0) - (v.min() ?? 0)
        }
        let front = spans[0] >= spans[1] ? horizontal[1] : horizontal[0]
        let left = vcross(upUnit, front)
        let leftValues = all.map { vdot($0, left) }
        let leftMid = ((leftValues.min() ?? 0) + (leftValues.max() ?? 0)) / 2
        let leftHalf = max(((leftValues.max() ?? 0) - (leftValues.min() ?? 0)) / 2, 1e-9)

        struct Info { var height: Double; var side: Double; var area: Double }
        let infos = pieces.map { piece -> Info in
            let center = piece.positions.reduce(Vec3.zero, +) / Double(max(piece.positions.count, 1))
            return Info(height: (vdot(center, upUnit) - lo) / (hi - lo), side: (vdot(center, left) - leftMid) / leftHalf, area: piece.surfaceArea)
        }
        let torsoIndices = pieces.indices.filter { (pieces[$0].anatomicalLabel ?? "").hasSuffix(" front") || (pieces[$0].anatomicalLabel ?? "").hasSuffix(" back") }
        let headIndex = pieces.indices.filter { !torsoIndices.contains($0) }.max { infos[$0].height < infos[$1].height }
        var counts: [String: Int] = [:]
        var names: [Int: String] = [:]
        for index in pieces.indices {
            let info = infos[index]
            let label = pieces[index].anatomicalLabel ?? ""
            if torsoIndices.contains(index) {
                names[index] = label.hasSuffix(" front") ? "Torso front" : "Torso back"
            } else if index == headIndex, info.height > 0.5 {
                names[index] = "Head"
            } else if label == "foot" {
                names[index] = info.side >= 0 ? "Left Leg" : "Right Leg"
            } else if abs(info.side) > 0.2 {
                names[index] = info.side >= 0 ? "Left Arm" : "Right Arm"
            } else {
                names[index] = "Extremity"
            }
        }
        // Repeated names get numbers so panels stay distinguishable.
        for name in names.values { counts[name, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return pieces.indices.map { index in
            var name = names[index]!
            if counts[name]! > 1 { seen[name, default: 0] += 1; name += " \(seen[name]!)" }
            let piece = pieces[index]
            return MeshComponent(id: piece.id, positions: piece.positions, triangles: piece.triangles, sourceVertices: piece.sourceVertices, anatomicalLabel: name)
        }
    }
}

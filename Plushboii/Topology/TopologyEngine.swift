import Foundation

enum TopologyEngine {
    static let defaultTolerance = 0.05
    static let maximumRemapAttempts = 6

    /// Flattens every surface segment bounded by `seams` into a verified 2D UV island.
    /// Anything that cannot be verified within `tolerance` is rejected with an error, never returned.
    static func flatten(
        positions: [Vec3],
        triangles: [Int32],
        seams: [[Int]],
        fabric: FabricProfile = .none,
        tolerance: Double = defaultTolerance,
        refine: Bool = true
    ) throws -> FlatteningResult {
        guard tolerance.isFinite, tolerance > 0 else { throw FlatteningError.invalidTolerance }
        try fabric.validated()
        try validateMesh(positions: positions, triangles: triangles)

        var cuts = Set<UInt64>()
        for seam in seams {
            for index in seam where index < 0 || index >= positions.count {
                throw FlatteningError.invalidMesh("seam vertex \(index) is out of range")
            }
            for (a, b) in zip(seam, seam.dropFirst()) where a != b {
                cuts.insert(SurfaceCutter.edgeKey(Int32(a), Int32(b)))
            }
        }

        let whole = SurfacePatch.whole(positions: positions, triangles: triangles)
        let segments = try SurfaceCutter.components(of: whole, cutting: cuts)
        let flattened = try segments.enumerated().flatMap { index, patch in
            try flattenSegment(patch, index: index, fabric: fabric, tolerance: tolerance, refine: refine)
        }
        let islands = flattened.enumerated().map { index, island in
            UVIsland(
                segmentIndex: index,
                triangles: island.triangles,
                uv: island.uv,
                sourceVertex: island.sourceVertex,
                darts: island.darts,
                geometryReport: island.geometryReport,
                report: island.report,
                log: island.log
            )
        }
        return FlatteningResult(islands: islands, fabric: fabric)
    }

    // MARK: Segment pipeline

    private struct Candidate {
        let uv: [Vec2]
        let report: DistortionReport
    }

    private static func flattenSegment(
        _ patch: SurfacePatch,
        index: Int,
        fabric: FabricProfile,
        tolerance: Double,
        refine: Bool,
        splitDepth: Int = 0
    ) throws -> [UVIsland] {
        var current = patch
        var darts: [(apex: Int, path: [Int])] = []
        var log: [VerificationRecord] = []

        while true {
            let candidate = try remap(current, segment: index, fabric: fabric, tolerance: tolerance, refine: refine, dartCount: darts.count, log: &log)
            if candidate.report.passed {
                let island = try finalize(
                    current, candidate: candidate, index: index, fabric: fabric,
                    tolerance: tolerance, darts: darts, log: log, refine: refine
                )
                // A fold-over without flipped triangles still makes the panel overlap itself.
                if refine, splitDepth < 2, boundaryCrossesItself(island),
                   let split = try? adaptiveSplit(
                    current, index: index, fabric: fabric, tolerance: tolerance,
                    refine: refine, depth: splitDepth, requireClean: true
                   ) {
                    return split
                }
                // A panel that stays badly stretched is cut again when that clearly lowers the stretch.
                if refine, splitDepth < 3, fabric == .none,
                   let before = meanStretch([island], reference: current), before > stretchSplitThreshold,
                   let split = try? adaptiveSplit(
                    current, index: index, fabric: fabric, tolerance: tolerance,
                    refine: refine, depth: splitDepth, requireClean: true, improveOver: before
                   ) {
                    return split
                }
                return [island]
            }
            let dartPath = darts.count < fabric.maxDarts
                ? DartPlanner.nextDartPath(in: current)
                : nil
            if splitDepth < 2, (dartPath == nil || darts.count >= min(2, fabric.maxDarts)),
               let split = try adaptiveSplit(
                current,
                index: index,
                fabric: fabric,
                tolerance: tolerance,
                refine: refine,
                depth: splitDepth
               ) {
                return split
            }
            guard let path = dartPath else {
                throw FlatteningError.distortionExceeded(
                    segment: index,
                    areaDelta: candidate.report.areaDelta,
                    meanLocal: candidate.report.meanLocalDistortion,
                    flipped: candidate.report.flippedTriangles,
                    darts: darts.count
                )
            }
            var edges = Set<UInt64>()
            for (a, b) in zip(path, path.dropFirst()) { edges.insert(SurfaceCutter.edgeKey(a, b)) }
            let pieces = try SurfaceCutter.components(of: current, cutting: edges)
            guard pieces.count == 1 else {
                throw FlatteningError.distortionExceeded(
                    segment: index,
                    areaDelta: candidate.report.areaDelta,
                    meanLocal: candidate.report.meanLocalDistortion,
                    flipped: candidate.report.flippedTriangles,
                    darts: darts.count
                )
            }
            darts.append((Int(current.origin[Int(path[0])]), path.map { current.origin[Int($0)] }))
            current = pieces[0]
        }
    }

    private static func adaptiveSplit(
        _ patch: SurfacePatch,
        index: Int,
        fabric: FabricProfile,
        tolerance: Double,
        refine: Bool,
        depth: Int,
        requireClean: Bool = false,
        improveOver: Double? = nil
    ) throws -> [UVIsland]? {
        guard depth < (improveOver == nil ? 2 : 3) else { return nil }
        var best: (islands: [UVIsland], stretch: Double)?
        for path in try PanelSplitPlanner.candidatePaths(in: patch).prefix(improveOver == nil ? 4 : 8) {
            let cuts = Set(zip(path, path.dropFirst()).map { SurfaceCutter.edgeKey($0, $1) })
            let pieces = try SurfaceCutter.components(of: patch, cutting: cuts)
            guard pieces.count == 2,
                  pieces.allSatisfy({ $0.triangleCount >= 4 }) else {
                continue
            }
            do {
                let first = try flattenSegment(
                    pieces[0], index: index, fabric: fabric, tolerance: tolerance, refine: refine,
                    splitDepth: depth + 1
                )
                let second = try flattenSegment(
                    pieces[1], index: index, fabric: fabric, tolerance: tolerance, refine: refine,
                    splitDepth: depth + 1
                )
                let result = first + second
                if requireClean, result.contains(where: boundaryCrossesItself) { continue }
                guard let baseline = improveOver else { return result }
                if let stretch = meanStretch(result, reference: patch), stretch < baseline * 0.7,
                   stretch < (best?.stretch ?? .infinity) {
                    best = (result, stretch)
                }
                continue
            } catch let error as FlatteningError {
                switch error {
                case .distortionExceeded, .verificationFailed, .notDisc, .solverDidNotConverge:
                    continue
                default:
                    throw error
                }
            }
        }
        return best?.islands
    }

    /// Solve, verify and, when the distortion delta exceeds the tolerance, adjust the triangle
    /// weights and re-map. Returns the best candidate found; the caller decides whether it is acceptable.
    private static func remap(
        _ patch: SurfacePatch,
        segment: Int,
        fabric: FabricProfile,
        tolerance: Double,
        refine: Bool,
        dartCount: Int,
        log: inout [VerificationRecord]
    ) throws -> Candidate {
        let loop = try SurfaceCutter.boundaryLoop(of: patch, segment: segment)
        var weights = [Double](repeating: 1, count: patch.triangleCount)
        var best: Candidate?

        for attempt in 1...maximumRemapAttempts {
            let solution = try LSCMSolver.solve(patch: patch, boundaryLoop: loop, weights: weights)
            let hasFlippedTriangles = DistortionVerifier.triangleAreas(
                positions: patch.positions,
                triangles: patch.triangles,
                uv: solution.uv
            ).signedArea2D.contains(where: { $0 <= 0 })
            let uv = dartCount == 0 && !hasFlippedTriangles
                ? solution.uv
                : try AreaPreservingUVRefiner.refine(
                    patch: patch,
                    boundaryLoop: loop.map(Int.init),
                    initialUV: solution.uv
                )
            let report = DistortionVerifier.verify(
                positions: patch.positions, triangles: patch.triangles, uv: uv,
                areaFactor: 1, tolerance: tolerance, requireLocalAccuracy: fabric.isRigid
            )
            log.append(VerificationRecord(
                dartCount: dartCount, attempt: attempt, areaDelta: report.areaDelta,
                meanLocalDistortion: report.meanLocalDistortion,
                flippedTriangles: report.flippedTriangles, accepted: report.passed
            ))
            let candidate = Candidate(uv: uv, report: report)
            let improved = best.map { score(report) < score($0.report) * 0.99 } ?? true
            if best == nil || score(report) < score(best!.report) { best = candidate }
            if report.passed { return candidate }
            if !improved { break }
            weights = reweighted(weights, patch: patch, uv: uv)
        }
        return best!
    }

    static let stretchSplitThreshold = 0.2

    /// Triangle-weighted mean stretch of islands cut from `reference`; nil if any triangle flipped.
    private static func meanStretch(_ islands: [UVIsland], reference: SurfacePatch) -> Double? {
        guard let top = reference.origin.max() else { return nil }
        var positions = [Vec3](repeating: .zero, count: top + 1)
        for (local, origin) in reference.origin.enumerated() { positions[origin] = reference.positions[local] }
        var weighted = 0.0, triangles = 0
        for island in islands {
            let quality = PatternQualityMap.evaluate(island: island, positions: positions)
            guard quality.flippedTriangles == 0, quality.meanStretch.isFinite else { return nil }
            weighted += quality.meanStretch * Double(island.triangles.count / 3)
            triangles += island.triangles.count / 3
        }
        return triangles > 0 ? weighted / Double(triangles) : nil
    }

    private static func boundaryCrossesItself(_ island: UVIsland) -> Bool {
        guard let indices = try? PatternGeometry.boundaryIndices(of: island) else { return false }
        let pts = indices.map { island.uv[Int($0)] }
        let n = pts.count
        guard n >= 4 else { return false }
        func side(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Double { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        for i in 0..<n {
            let p1 = pts[i], p2 = pts[(i + 1) % n]
            for j in stride(from: i + 2, to: n, by: 1) where !(i == 0 && j == n - 1) {
                let p3 = pts[j], p4 = pts[(j + 1) % n]
                if side(p3, p4, p1) * side(p3, p4, p2) < 0, side(p1, p2, p3) * side(p1, p2, p4) < 0 { return true }
            }
        }
        return false
    }

    private static func score(_ report: DistortionReport) -> Double {
        Double(report.flippedTriangles) * 1e6 + report.areaDelta + report.meanLocalDistortion
    }

    /// Triangles whose area was pushed far from its 3D area get a lower conformal weight, which lets
    /// them shear instead of being forced to stay conformal, and the surface is re-mapped.
    private static func reweighted(_ weights: [Double], patch: SurfacePatch, uv: [Vec2]) -> [Double] {
        let areas = DistortionVerifier.triangleAreas(positions: patch.positions, triangles: patch.triangles, uv: uv)
        var updated = weights
        for t in weights.indices {
            let ratio = abs(areas.signedArea2D[t]) / max(areas.area3D[t], 1e-300)
            let deviation = max(ratio, 1 / max(ratio, 1e-12))
            updated[t] = min(max(weights[t] / deviation, 1e-4), 1e4)
        }
        return updated
    }

    // MARK: Fabric adjustment and final verification

    private static func finalize(
        _ patch: SurfacePatch,
        candidate: Candidate,
        index: Int,
        fabric: FabricProfile,
        tolerance: Double,
        darts: [(apex: Int, path: [Int])],
        log: [VerificationRecord],
        refine: Bool
    ) throws -> UVIsland {
        var uv = candidate.uv
        var geometryReport = candidate.report
        if refine {
            let relaxed = ARAPRefiner.refine(patch: patch, initialUV: uv)
            let report = DistortionVerifier.verify(
                positions: patch.positions, triangles: patch.triangles, uv: relaxed,
                areaFactor: 1, tolerance: tolerance, requireLocalAccuracy: fabric.isRigid
            )
            if report.passed, report.flippedTriangles <= geometryReport.flippedTriangles {
                uv = relaxed
                geometryReport = report
            }
        }
        let matrix = fabric.scalingMatrix
        if case .twoWayStretch = fabric {
            let grain = Matrix2.rotation(-fabric.grainAngle)
            uv = uv.map { matrix.apply(grain.apply($0)) }
        }

        let finalReport = DistortionVerifier.verify(
            positions: patch.positions, triangles: patch.triangles, uv: uv,
            areaFactor: matrix.determinant, tolerance: tolerance, requireLocalAccuracy: fabric.isRigid
        )
        guard finalReport.passed else { throw FlatteningError.verificationFailed(segment: index) }

        return UVIsland(
            segmentIndex: index,
            triangles: patch.triangles,
            uv: uv,
            sourceVertex: patch.origin,
            darts: measure(darts, patch: patch, uv: uv),
            geometryReport: geometryReport,
            report: finalReport,
            log: log
        )
    }

    private static func measure(_ darts: [(apex: Int, path: [Int])], patch: SurfacePatch, uv: [Vec2]) -> [Dart] {
        darts.map { dart in
            var angleSum = 0.0
            if let apexIndex = patch.origin.firstIndex(of: dart.apex) {
                for t in 0..<patch.triangleCount {
                    for k in 0..<3 where Int(patch.triangles[t * 3 + k]) == apexIndex {
                        let o = uv[apexIndex]
                        let e1 = uv[Int(patch.triangles[t * 3 + (k + 1) % 3])] - o
                        let e2 = uv[Int(patch.triangles[t * 3 + (k + 2) % 3])] - o
                        let cosine = (e1 * e2).sum() / (vlength(e1) * vlength(e2))
                        angleSum += acos(min(1, max(-1, cosine)))
                    }
                }
            }
            let mouthCopies = patch.origin.indices.filter { patch.origin[$0] == dart.path.last }
            let mouth = mouthCopies.count == 2 ? vlength(uv[mouthCopies[0]] - uv[mouthCopies[1]]) : 0
            let legLength = zip(dart.path, dart.path.dropFirst()).reduce(0.0) { total, pair in
                total + vlength(originPosition(pair.0, patch) - originPosition(pair.1, patch))
            }
            return Dart(
                apexVertex: dart.apex,
                pathVertices: dart.path,
                openingAngle: max(0, 2 * Double.pi - angleSum),
                mouthWidth: mouth,
                legLength: legLength
            )
        }
    }

    private static func originPosition(_ vertex: Int, _ patch: SurfacePatch) -> Vec3 {
        guard let local = patch.origin.firstIndex(of: vertex) else { return .zero }
        return patch.positions[local]
    }

    private static func validateMesh(positions: [Vec3], triangles: [Int32]) throws {
        guard positions.count >= 3, triangles.count >= 3, triangles.count % 3 == 0 else {
            throw FlatteningError.invalidMesh("it needs at least one triangle")
        }
        guard positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw FlatteningError.invalidMesh("a vertex coordinate is not finite")
        }
        for t in 0..<(triangles.count / 3) {
            let a = triangles[t * 3], b = triangles[t * 3 + 1], c = triangles[t * 3 + 2]
            guard [a, b, c].allSatisfy({ $0 >= 0 && Int($0) < positions.count }) else {
                throw FlatteningError.invalidMesh("a triangle index is out of range")
            }
            guard a != b, b != c, a != c else { throw FlatteningError.degenerateTriangle }
        }
    }
}

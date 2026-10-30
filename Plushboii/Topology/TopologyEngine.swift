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
        tolerance: Double = defaultTolerance
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
        let islands = try segments.enumerated().map { index, patch in
            try flattenSegment(patch, index: index, fabric: fabric, tolerance: tolerance)
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
        tolerance: Double
    ) throws -> UVIsland {
        var current = patch
        var darts: [(apex: Int, path: [Int])] = []
        var log: [VerificationRecord] = []

        while true {
            let candidate = try remap(current, segment: index, fabric: fabric, tolerance: tolerance, dartCount: darts.count, log: &log)
            if candidate.report.passed {
                return try finalize(
                    current, candidate: candidate, index: index, fabric: fabric,
                    tolerance: tolerance, darts: darts, log: log
                )
            }
            guard darts.count < fabric.maxDarts, let path = DartPlanner.nextDartPath(in: current) else {
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

    /// Solve, verify and, when the distortion delta exceeds the tolerance, adjust the triangle
    /// weights and re-map. Returns the best candidate found; the caller decides whether it is acceptable.
    private static func remap(
        _ patch: SurfacePatch,
        segment: Int,
        fabric: FabricProfile,
        tolerance: Double,
        dartCount: Int,
        log: inout [VerificationRecord]
    ) throws -> Candidate {
        let loop = try SurfaceCutter.boundaryLoop(of: patch, segment: segment)
        var weights = [Double](repeating: 1, count: patch.triangleCount)
        var best: Candidate?

        for attempt in 1...maximumRemapAttempts {
            let solution = try LSCMSolver.solve(patch: patch, boundaryLoop: loop, weights: weights)
            let report = DistortionVerifier.verify(
                positions: patch.positions, triangles: patch.triangles, uv: solution.uv,
                areaFactor: 1, tolerance: tolerance, requireLocalAccuracy: fabric.isRigid
            )
            log.append(VerificationRecord(
                dartCount: dartCount, attempt: attempt, areaDelta: report.areaDelta,
                meanLocalDistortion: report.meanLocalDistortion,
                flippedTriangles: report.flippedTriangles, accepted: report.passed
            ))
            let candidate = Candidate(uv: solution.uv, report: report)
            let improved = best.map { score(report) < score($0.report) * 0.99 } ?? true
            if best == nil || score(report) < score(best!.report) { best = candidate }
            if report.passed { return candidate }
            if !improved { break }
            weights = reweighted(weights, patch: patch, uv: solution.uv)
        }
        return best!
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
        log: [VerificationRecord]
    ) throws -> UVIsland {
        var uv = candidate.uv
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
            geometryReport: candidate.report,
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

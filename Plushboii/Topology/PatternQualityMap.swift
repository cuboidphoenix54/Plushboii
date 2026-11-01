import Foundation

/// Per-triangle stretch of a flattened island against its 3D source, for a pattern-quality heatmap.
enum PatternQualityMap {
    /// Stretch at which a triangle is shown as fully red.
    static let saturationStretch = 0.35

    struct IslandQuality: Sendable, Equatable {
        let segmentIndex: Int
        /// max(σ1, 1/σ2) - 1 per triangle, after removing the island's uniform scale. 0 is a perfect isometry.
        let triangleStretch: [Double]
        /// 0...1 severity per island vertex (area-weighted over adjacent triangles).
        let vertexSeverity: [Double]
        let worstStretch: Double
        let meanStretch: Double
        let flippedTriangles: Int
    }

    static func evaluate(island: UVIsland, positions: [Vec3]) -> IslandQuality {
        let count = island.triangles.count / 3
        var stretch = [Double](repeating: 0, count: count)
        var area3D = [Double](repeating: 0, count: count)
        var flipped = 0

        var total3D = 0.0, total2D = 0.0
        for t in 0..<count {
            let (a, b, c) = corners(island, t)
            let e1 = positions[island.sourceVertex[b]] - positions[island.sourceVertex[a]]
            let e2 = positions[island.sourceVertex[c]] - positions[island.sourceVertex[a]]
            area3D[t] = 0.5 * vlength(vcross(e1, e2))
            let u1 = island.uv[b] - island.uv[a], u2 = island.uv[c] - island.uv[a]
            total3D += area3D[t]
            total2D += 0.5 * abs(u1.x * u2.y - u1.y * u2.x)
        }
        let scale = total3D > 0 && total2D > 0 ? (total2D / total3D).squareRoot() : 1

        var worst = 0.0, weightedSum = 0.0
        for t in 0..<count {
            guard area3D[t] > 1e-18 else { continue }
            let (a, b, c) = corners(island, t)
            let e1 = island.sourcePosition(a, positions), e2 = island.sourcePosition(b, positions), e3 = island.sourcePosition(c, positions)
            let p1 = e2 - e1, p2 = e3 - e1
            let l1 = vlength(p1)
            let x1 = p1 / l1
            let p2x = vdot(p2, x1)
            let p2y = vlength(p2 - x1 * p2x)
            // Local 2D frame of the 3D triangle: P = [[l1, p2x], [0, p2y]] (columns are the edges).
            let u1 = (island.uv[b] - island.uv[a]) / scale, u2 = (island.uv[c] - island.uv[a]) / scale
            let det3 = l1 * p2y
            // J = U * P^-1 with U = [u1 u2] as columns.
            let j00 = (u1.x * p2y) / det3
            let j01 = (-u1.x * p2x + u2.x * l1) / det3
            let j10 = (u1.y * p2y) / det3
            let j11 = (-u1.y * p2x + u2.y * l1) / det3
            let determinant = j00 * j11 - j01 * j10
            if determinant <= 0 {
                flipped += 1
                stretch[t] = .infinity
                worst = .infinity
                continue
            }
            let frobenius = j00 * j00 + j01 * j01 + j10 * j10 + j11 * j11
            let discriminant = max(0, frobenius * frobenius - 4 * determinant * determinant).squareRoot()
            let sigmaMax = ((frobenius + discriminant) / 2).squareRoot()
            let sigmaMin = max(((frobenius - discriminant) / 2).squareRoot(), 1e-12)
            let value = max(sigmaMax, 1 / sigmaMin) - 1
            stretch[t] = value
            worst = max(worst, value)
            weightedSum += value * area3D[t]
        }

        var severitySum = [Double](repeating: 0, count: island.uv.count)
        var weight = [Double](repeating: 0, count: island.uv.count)
        for t in 0..<count {
            let severity = min(1, stretch[t] / saturationStretch)
            let (a, b, c) = corners(island, t)
            for v in [a, b, c] {
                severitySum[v] += severity * area3D[t]
                weight[v] += area3D[t]
            }
        }
        let vertexSeverity = zip(severitySum, weight).map { $1 > 0 ? $0 / $1 : 0 }
        let finiteStretch = worst.isFinite ? worst : .infinity
        return IslandQuality(
            segmentIndex: island.segmentIndex,
            triangleStretch: stretch,
            vertexSeverity: vertexSeverity,
            worstStretch: finiteStretch,
            meanStretch: total3D > 0 ? weightedSum / total3D : 0,
            flippedTriangles: flipped
        )
    }

    /// Severity per original mesh vertex (the worst value over every island copy of that vertex).
    static func meshVertexSeverity(result: FlatteningResult, positions: [Vec3]) -> [Double] {
        var severity = [Double](repeating: 0, count: positions.count)
        for island in result.islands {
            let quality = evaluate(island: island, positions: positions)
            for (local, source) in island.sourceVertex.enumerated() {
                severity[source] = max(severity[source], quality.vertexSeverity[local])
            }
        }
        return severity
    }

    /// White (no stretch) to red (saturated).
    static func heatColor(_ severity: Double) -> (red: Double, green: Double, blue: Double) {
        let s = min(1, max(0, severity.isFinite ? severity : 1))
        return (1, 1 - 0.85 * s, 1 - 0.85 * s)
    }

    private static func corners(_ island: UVIsland, _ t: Int) -> (Int, Int, Int) {
        (Int(island.triangles[t * 3]), Int(island.triangles[t * 3 + 1]), Int(island.triangles[t * 3 + 2]))
    }
}

extension UVIsland {
    fileprivate func sourcePosition(_ local: Int, _ positions: [Vec3]) -> Vec3 {
        positions[sourceVertex[local]]
    }
}

/// Compares the two sewn edges of every cut, including cuts the flattener added on its own, which are
/// not part of any suggested seam path.
enum StitchAudit {
    struct Report: Sendable, Equatable {
        /// Σ|Δlength| / Σ mean length for the worst pair of panels that share a cut.
        let worstMismatch: Double
        /// Source edges that lie on a panel boundary twice, i.e. edges that are sewn.
        let sewnEdges: Int
        /// Boundary source edges that appear only once (a true opening, not a seam).
        let openEdges: Int
    }

    static func audit(_ islands: [UVIsland]) -> Report {
        struct Copy { let island: Int; let length: Double }
        var copies: [UInt64: [Copy]] = [:]
        for (index, island) in islands.enumerated() {
            guard let loop = try? PatternGeometry.boundaryIndices(of: island) else { continue }
            for k in loop.indices {
                let a = Int(loop[k]), b = Int(loop[(k + 1) % loop.count])
                let key = SurfaceCutter.edgeKey(Int32(island.sourceVertex[a]), Int32(island.sourceVertex[b]))
                copies[key, default: []].append(Copy(island: index, length: vlength(island.uv[a] - island.uv[b])))
            }
        }
        var totals: [UInt64: (delta: Double, mean: Double)] = [:]
        var sewn = 0, open = 0
        for (_, pair) in copies {
            guard pair.count == 2 else { open += 1; continue }
            sewn += 1
            let low = min(pair[0].island, pair[1].island), high = max(pair[0].island, pair[1].island)
            let key = UInt64(low) << 32 | UInt64(high)
            var entry = totals[key] ?? (0, 0)
            entry.delta += abs(pair[0].length - pair[1].length)
            entry.mean += (pair[0].length + pair[1].length) / 2
            totals[key] = entry
        }
        let worst = totals.values.map { $0.mean > 0 ? $0.delta / $0.mean : 0 }.max() ?? 0
        return Report(worstMismatch: worst, sewnEdges: sewn, openEdges: open)
    }
}

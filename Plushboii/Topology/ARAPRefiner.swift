import Foundation

/// As-rigid-as-possible refinement of a flattened panel (Liu et al. 2008, local/global form).
///
/// The conformal solve keeps angles but lets individual triangles shrink or blow up, which is what shows up as
/// puckering and mismatched seam lengths. Each iteration fits the best rotation of every 3D triangle onto its
/// current flattened shape, then moves the vertices to the least-squares position that honours all of those
/// rigid targets. The boundary is free, so a panel can relax into its natural outline.
enum ARAPRefiner {
    private struct Rest {
        var x: [Vec2]
        var weights: [Double]
        var area: Double
    }

    static func refine(
        patch: SurfacePatch,
        initialUV: [Vec2],
        iterations: Int = 40
    ) -> [Vec2] {
        let triangleCount = patch.triangleCount
        guard initialUV.count == patch.positions.count, triangleCount > 0,
              initialUV.allSatisfy({ $0.x.isFinite && $0.y.isFinite })
        else { return initialUV }

        var rest: [Rest] = []
        rest.reserveCapacity(triangleCount)
        for t in 0..<triangleCount {
            guard let entry = restShape(patch, t) else { return initialUV }
            rest.append(entry)
        }

        let vertexCount = patch.positions.count
        var diagonal = [Double](repeating: 0, count: vertexCount)
        var neighbours = [[(vertex: Int, weight: Double)]](repeating: [], count: vertexCount)
        for t in 0..<triangleCount {
            let v = corners(patch, t)
            for k in 0..<3 {
                let i = v[k], j = v[(k + 1) % 3]
                let w = rest[t].weights[k]
                diagonal[i] += w
                diagonal[j] += w
                neighbours[i].append((j, w))
                neighbours[j].append((i, w))
            }
        }

        var uv = initialUV
        var best = initialUV
        var bestFlips = flips(patch, uv)
        var bestEnergy = energy(patch, rest, uv)
        var previous = bestEnergy

        for _ in 0..<iterations {
            var rhsX = [Double](repeating: 0, count: vertexCount)
            var rhsY = [Double](repeating: 0, count: vertexCount)
            for t in 0..<triangleCount {
                let v = corners(patch, t)
                let rotation = bestRotation(patch, rest[t], v, uv)
                for k in 0..<3 {
                    let i = v[k], j = v[(k + 1) % 3]
                    let w = rest[t].weights[k]
                    let d = rotation(rest[t].x[k] - rest[t].x[(k + 1) % 3]) * w
                    rhsX[i] += d.x; rhsY[i] += d.y
                    rhsX[j] -= d.x; rhsY[j] -= d.y
                }
            }
            let solvedX = conjugateGradient(diagonal: diagonal, neighbours: neighbours, rhs: rhsX, start: uv.map(\.x))
            let solvedY = conjugateGradient(diagonal: diagonal, neighbours: neighbours, rhs: rhsY, start: uv.map(\.y))
            let next = (0..<vertexCount).map { Vec2(solvedX[$0], solvedY[$0]) }
            guard next.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { break }

            // A full step can fold strongly curved panels over themselves, so shorten it until no
            // triangle that was valid becomes flipped.
            let flipsBefore = flips(patch, uv)
            let floor = min(minimumAreaRatio(patch, rest, uv), collapseFloor)
            func acceptable(_ candidate: [Vec2]) -> Bool {
                flips(patch, candidate) <= flipsBefore && minimumAreaRatio(patch, rest, candidate) >= floor
            }
            var step = 1.0
            var candidate = next
            while !acceptable(candidate), step > 1.0 / 64 {
                step *= 0.5
                candidate = (0..<vertexCount).map { uv[$0] + (next[$0] - uv[$0]) * step }
            }
            guard acceptable(candidate) else { break }
            uv = candidate
            let current = energy(patch, rest, uv)
            let currentFlips = flips(patch, uv)
            if currentFlips < bestFlips || (currentFlips == bestFlips && current < bestEnergy) {
                bestFlips = currentFlips; bestEnergy = current; best = uv
            }
            if previous - current < 1e-5 * max(previous, 1e-30) { break }
            previous = current
        }
        return best
    }

    /// Triangles must keep at least this share of their 3D area, which stops ARAP trading a few collapsed
    /// triangles for a lower total energy.
    private static let collapseFloor = 0.1

    private static func minimumAreaRatio(_ patch: SurfacePatch, _ rest: [Rest], _ uv: [Vec2]) -> Double {
        let areas = signedAreas(patch, uv)
        var worst = Double.infinity
        for t in rest.indices { worst = min(worst, areas[t] / rest[t].area) }
        return worst
    }

    private static func flips(_ patch: SurfacePatch, _ uv: [Vec2]) -> Int {
        signedAreas(patch, uv).filter { $0 <= 0 }.count
    }

    // MARK: Rest shapes

    /// The triangle laid flat in its own plane, with the cotangent weight of every edge (opposite angle / 2).
    private static func restShape(_ patch: SurfacePatch, _ t: Int) -> Rest? {
        let v = corners(patch, t)
        let p0 = patch.positions[v[0]], p1 = patch.positions[v[1]], p2 = patch.positions[v[2]]
        let e1 = p1 - p0
        let l1 = vlength(e1)
        guard l1 > 1e-14 else { return nil }
        let ex = e1 / l1
        let e2 = p2 - p0
        let px = vdot(e2, ex)
        let py = vlength(e2 - ex * px)
        guard py > 1e-14 else { return nil }
        let x = [Vec2(0, 0), Vec2(l1, 0), Vec2(px, py)]

        func cotangent(at k: Int) -> Double {
            let a = x[(k + 1) % 3] - x[k], b = x[(k + 2) % 3] - x[k]
            let cross = abs(a.x * b.y - a.y * b.x)
            return cross > 1e-18 ? vdot(a, b) / cross : 0
        }
        // Edge k joins corner k to corner k + 1, so it is opposite corner k + 2. Obtuse corners give negative
        // weights; they are kept because the three weights together reproduce the triangle's exact
        // isometric energy (area times squared deviation from a rotation), and clamping them would let
        // obtuse triangles collapse almost for free.
        let weights = (0..<3).map { cotangent(at: ($0 + 2) % 3) * 0.5 }
        return Rest(x: x, weights: weights, area: 0.5 * l1 * py)
    }

    private static func corners(_ patch: SurfacePatch, _ t: Int) -> [Int] {
        [Int(patch.triangles[t * 3]), Int(patch.triangles[t * 3 + 1]), Int(patch.triangles[t * 3 + 2])]
    }

    // MARK: Local step

    /// Rotation that best maps the rest edges of triangle `t` onto their current flattened edges.
    private static func bestRotation(_ patch: SurfacePatch, _ rest: Rest, _ v: [Int], _ uv: [Vec2]) -> (Vec2) -> Vec2 {
        var s00 = 0.0, s01 = 0.0, s10 = 0.0, s11 = 0.0
        for k in 0..<3 {
            let w = rest.weights[k]
            let du = uv[v[k]] - uv[v[(k + 1) % 3]]
            let dx = rest.x[k] - rest.x[(k + 1) % 3]
            s00 += w * du.x * dx.x
            s01 += w * du.x * dx.y
            s10 += w * du.y * dx.x
            s11 += w * du.y * dx.y
        }
        let angle = atan2(s10 - s01, s00 + s11)
        let c = cos(angle), s = sin(angle)
        return { Vec2(c * $0.x - s * $0.y, s * $0.x + c * $0.y) }
    }

    // MARK: Global step

    /// Jacobi-preconditioned conjugate gradient on the cotangent Laplacian. The system is singular only along
    /// constants, and the right-hand side sums to zero, so it is consistent.
    private static func conjugateGradient(
        diagonal: [Double],
        neighbours: [[(vertex: Int, weight: Double)]],
        rhs: [Double],
        start: [Double]
    ) -> [Double] {
        let n = rhs.count
        func apply(_ x: [Double]) -> [Double] {
            var out = [Double](repeating: 0, count: n)
            for i in 0..<n {
                var value = diagonal[i] * x[i]
                for (j, w) in neighbours[i] { value -= w * x[j] }
                out[i] = value
            }
            return out
        }
        func centered(_ x: [Double]) -> [Double] {
            let mean = DenseKernels.sum(x) / Double(n)
            return x.map { $0 - mean }
        }

        var x = start
        let ax = apply(x)
        var r = centered((0..<n).map { rhs[$0] - ax[$0] })
        let inverse = diagonal.map { $0 > 1e-30 ? 1 / $0 : 1 }
        var z = (0..<n).map { r[$0] * inverse[$0] }
        var p = z
        var rz = DenseKernels.dot(r, z)
        let target = 1e-10 * max(DenseKernels.dot(rhs, rhs), 1e-30)

        for _ in 0..<400 {
            if DenseKernels.dot(r, r) < target { break }
            let ap = apply(p)
            let denominator = DenseKernels.dot(p, ap)
            guard denominator > 1e-300 else { break }
            let alpha = rz / denominator
            for i in 0..<n { x[i] += alpha * p[i]; r[i] -= alpha * ap[i] }
            z = (0..<n).map { r[$0] * inverse[$0] }
            let next = DenseKernels.dot(r, z)
            let beta = next / max(rz, 1e-300)
            rz = next
            for i in 0..<n { p[i] = z[i] + beta * p[i] }
        }
        return x
    }

    // MARK: Energy and validity

    private static func energy(_ patch: SurfacePatch, _ rest: [Rest], _ uv: [Vec2]) -> Double {
        var total = 0.0
        for t in rest.indices {
            let v = corners(patch, t)
            let rotation = bestRotation(patch, rest[t], v, uv)
            for k in 0..<3 {
                let du = uv[v[k]] - uv[v[(k + 1) % 3]]
                let target = rotation(rest[t].x[k] - rest[t].x[(k + 1) % 3])
                let delta = du - target
                total += rest[t].weights[k] * vdot(delta, delta)
            }
        }
        return total
    }

    private static func signedAreas(_ patch: SurfacePatch, _ uv: [Vec2]) -> [Double] {
        (0..<patch.triangleCount).map { t in
            let v = corners(patch, t)
            let a = uv[v[1]] - uv[v[0]], b = uv[v[2]] - uv[v[0]]
            return 0.5 * (a.x * b.y - a.y * b.x)
        }
    }
}

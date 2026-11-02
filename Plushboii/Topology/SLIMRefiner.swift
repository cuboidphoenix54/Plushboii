import Foundation

/// Scalable locally injective mapping refinement (Rabinovich et al., ACM TOG 2017) of a flattened panel.
///
/// Minimises the symmetric Dirichlet energy, the sum over triangles of area × (σ1² + σ1⁻² + σ2² + σ2⁻²) where σ are
/// the singular values of the triangle's map from its own 3D shape to the flat panel. The energy is infinite for
/// a collapsed triangle, so a flip-free start stays flip-free, and it penalises stretch and compression equally,
/// which keeps seam lengths honest. Each iteration reweights a proxy least-squares problem per triangle, solves it
/// with conjugate gradients, and line-searches so that no triangle flips and the energy always drops.
enum SLIMRefiner {
    private struct Rest {
        var inverse: (a: Double, b: Double, c: Double, d: Double)
        var gram: (a: Double, b: Double, c: Double, d: Double)
        var area: Double
    }

    /// Largest proxy weight, which keeps nearly collapsed triangles from making the system singular.
    private static let weightCeiling = 1e8

    static func refine(patch: SurfacePatch, initialUV: [Vec2], iterations: Int = 30) -> [Vec2] {
        let triangleCount = patch.triangleCount
        guard initialUV.count == patch.positions.count, triangleCount > 0,
              initialUV.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let rest = restShapes(patch)
        else { return initialUV }

        let total3D = rest.reduce(0) { $0 + $1.area }
        let total2D = signedAreas(patch, initialUV).reduce(0, +)
        guard total3D > 0, total2D > 0 else { return initialUV }
        let scale = (total3D / total2D).squareRoot()
        var uv = initialUV.map { $0 * scale }
        guard signedAreas(patch, uv).allSatisfy({ $0 > 0 }), var energy = symmetricDirichlet(patch, rest, uv) else { return initialUV }

        let n = patch.positions.count
        for _ in 0..<iterations {
            let proxies = proxyTerms(patch, rest, uv)
            let rhs = assembleRHS(patch, rest, proxies, n)
            let solved = solve(patch, rest, proxies, rhs: rhs, start: uv)
            guard solved.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { break }

            var step = 1.0
            var accepted = false
            while step > 1.0 / 1024 {
                let candidate = (0..<n).map { uv[$0] + (solved[$0] - uv[$0]) * step }
                if signedAreas(patch, candidate).allSatisfy({ $0 > 1e-14 * max(total3D, 1e-30) }),
                   let value = symmetricDirichlet(patch, rest, candidate), value < energy {
                    let gain = energy - value
                    uv = candidate
                    accepted = true
                    let previous = energy
                    energy = value
                    if gain < 1e-6 * previous { return uv }
                    break
                }
                step *= 0.5
            }
            if !accepted { break }
        }
        return uv
    }

    /// Mean excess of the symmetric Dirichlet energy per unit area; 0 for an isometric map. The flat panel is
    /// rescaled to the 3D area first so only the shape of the distortion is measured. Nil if any triangle is flipped.
    static func meanExcessEnergy(patch: SurfacePatch, uv: [Vec2]) -> Double? {
        guard uv.count == patch.positions.count, let rest = restShapes(patch) else { return nil }
        let total3D = rest.reduce(0) { $0 + $1.area }
        let total2D = signedAreas(patch, uv).reduce(0, +)
        guard total3D > 0, total2D > 0 else { return nil }
        let scale = (total3D / total2D).squareRoot()
        let scaled = uv.map { $0 * scale }
        guard let energy = symmetricDirichlet(patch, rest, scaled) else { return nil }
        return energy / total3D - 4
    }

    // MARK: Rest shapes

    private static func restShapes(_ patch: SurfacePatch) -> [Rest]? {
        var rest: [Rest] = []
        rest.reserveCapacity(patch.triangleCount)
        for t in 0..<patch.triangleCount {
            let v = corners(patch, t)
            let p0 = patch.positions[v.0], p1 = patch.positions[v.1], p2 = patch.positions[v.2]
            let e1 = p1 - p0
            let l1 = vlength(e1)
            guard l1 > 1e-14 else { return nil }
            let ex = e1 / l1
            let e2 = p2 - p0
            let px = vdot(e2, ex)
            let py = vlength(e2 - ex * px)
            guard py > 1e-14 else { return nil }
            // Rest edge matrix is [[l1, px], [0, py]] with the edges as columns.
            let inv = (a: 1 / l1, b: -px / (l1 * py), c: 0.0, d: 1 / py)
            // C = D⁻¹ D⁻ᵀ
            let gram = (a: inv.a * inv.a + inv.b * inv.b, b: inv.b * inv.d, c: inv.b * inv.d, d: inv.d * inv.d)
            rest.append(Rest(inverse: inv, gram: gram, area: 0.5 * l1 * py))
        }
        return rest
    }

    private static func corners(_ patch: SurfacePatch, _ t: Int) -> (Int, Int, Int) {
        (Int(patch.triangles[t * 3]), Int(patch.triangles[t * 3 + 1]), Int(patch.triangles[t * 3 + 2]))
    }

    private static func signedAreas(_ patch: SurfacePatch, _ uv: [Vec2]) -> [Double] {
        (0..<patch.triangleCount).map { t in
            let v = corners(patch, t)
            let a = uv[v.1] - uv[v.0], b = uv[v.2] - uv[v.0]
            return 0.5 * (a.x * b.y - a.y * b.x)
        }
    }

    // MARK: Per-triangle Jacobian

    private struct Jacobian {
        var a: Double, b: Double, c: Double, d: Double
    }

    private static func jacobian(_ patch: SurfacePatch, _ rest: Rest, _ t: Int, _ uv: [Vec2]) -> Jacobian {
        let v = corners(patch, t)
        let e1 = uv[v.1] - uv[v.0], e2 = uv[v.2] - uv[v.0]
        let inv = rest.inverse
        // J = [e1 e2] D⁻¹
        return Jacobian(
            a: e1.x * inv.a, b: e1.x * inv.b + e2.x * inv.d,
            c: e1.y * inv.a, d: e1.y * inv.b + e2.y * inv.d
        )
    }

    /// Singular values and the rotation angles of J = R(φ) diag(s1, s2) R(θ).
    private static func decompose(_ j: Jacobian) -> (s1: Double, s2: Double, phi: Double, theta: Double) {
        let e = (j.a + j.d) / 2, f = (j.a - j.d) / 2
        let g = (j.c + j.b) / 2, h = (j.c - j.b) / 2
        let q = (e * e + h * h).squareRoot(), r = (f * f + g * g).squareRoot()
        let a1 = atan2(g, f), a2 = atan2(h, e)
        return (q + r, q - r, (a2 + a1) / 2, (a2 - a1) / 2)
    }

    private static func symmetricDirichlet(_ patch: SurfacePatch, _ rest: [Rest], _ uv: [Vec2]) -> Double? {
        var total = 0.0
        for t in rest.indices {
            let s = decompose(jacobian(patch, rest[t], t, uv))
            guard s.s1 > 1e-12, s.s2 > 1e-12 else { return nil }
            total += rest[t].area * (s.s1 * s.s1 + 1 / (s.s1 * s.s1) + s.s2 * s.s2 + 1 / (s.s2 * s.s2))
        }
        return total.isFinite ? total : nil
    }

    // MARK: Proxy problem

    private struct Proxy {
        /// M = WᵀW, symmetric.
        var m00: Double, m01: Double, m11: Double
        /// Target rotation R (closest rotation to J).
        var r00: Double, r01: Double, r10: Double, r11: Double
    }

    private static func weightSquared(_ s: Double) -> Double {
        if abs(s - 1) < 1e-6 { return 4 }
        let value = (s - 1 / (s * s * s)) / (s - 1)
        return min(max(value, 1e-8), weightCeiling)
    }

    private static func proxyTerms(_ patch: SurfacePatch, _ rest: [Rest], _ uv: [Vec2]) -> [Proxy] {
        rest.indices.map { t in
            let s = decompose(jacobian(patch, rest[t], t, uv))
            let w1 = weightSquared(s.s1), w2 = weightSquared(s.s2)
            let c = cos(s.phi), sn = sin(s.phi)
            // M = U diag(w1², w2²) Uᵀ with U = R(φ)
            let m00 = c * c * w1 + sn * sn * w2
            let m11 = sn * sn * w1 + c * c * w2
            let m01 = c * sn * (w1 - w2)
            // R = R(φ + θ), the polar rotation of J.
            let angle = s.phi + s.theta
            let cr = cos(angle), sr = sin(angle)
            return Proxy(m00: m00, m01: m01, m11: m11, r00: cr, r01: -sr, r10: sr, r11: cr)
        }
    }

    // MARK: Global step

    private static func assembleRHS(_ patch: SurfacePatch, _ rest: [Rest], _ proxies: [Proxy], _ n: Int) -> [Vec2] {
        var rhs = [Vec2](repeating: .zero, count: n)
        for t in rest.indices {
            let p = proxies[t], inv = rest[t].inverse
            // Y = M R D⁻ᵀ, with D⁻ᵀ = [[inv.a, 0], [inv.b, inv.d]]
            let mr00 = p.m00 * p.r00 + p.m01 * p.r10, mr01 = p.m00 * p.r01 + p.m01 * p.r11
            let mr10 = p.m01 * p.r00 + p.m11 * p.r10, mr11 = p.m01 * p.r01 + p.m11 * p.r11
            let col0 = Vec2(mr00 * inv.a + mr01 * inv.b, mr10 * inv.a + mr11 * inv.b)
            let col1 = Vec2(mr01 * inv.d, mr11 * inv.d)
            scatter(patch, t, col0, col1, rest[t].area, into: &rhs)
        }
        return rhs
    }

    private static func scatter(_ patch: SurfacePatch, _ t: Int, _ col0: Vec2, _ col1: Vec2, _ area: Double, into out: inout [Vec2]) {
        let v = corners(patch, t)
        out[v.1] += col0 * area
        out[v.2] += col1 * area
        out[v.0] -= (col0 + col1) * area
    }

    private static func applyOperator(_ patch: SurfacePatch, _ rest: [Rest], _ proxies: [Proxy], _ x: [Vec2]) -> [Vec2] {
        var out = [Vec2](repeating: .zero, count: x.count)
        for t in rest.indices {
            let p = proxies[t], c = rest[t].gram
            let v = corners(patch, t)
            let e1 = x[v.1] - x[v.0], e2 = x[v.2] - x[v.0]
            // Ds = [e1 e2]; Y = M Ds C
            let ds00 = e1.x, ds10 = e1.y, ds01 = e2.x, ds11 = e2.y
            let md00 = p.m00 * ds00 + p.m01 * ds10, md01 = p.m00 * ds01 + p.m01 * ds11
            let md10 = p.m01 * ds00 + p.m11 * ds10, md11 = p.m01 * ds01 + p.m11 * ds11
            let col0 = Vec2(md00 * c.a + md01 * c.c, md10 * c.a + md11 * c.c)
            let col1 = Vec2(md00 * c.b + md01 * c.d, md10 * c.b + md11 * c.d)
            scatter(patch, t, col0, col1, rest[t].area, into: &out)
        }
        return out
    }

    private static func diagonal(_ patch: SurfacePatch, _ rest: [Rest], _ proxies: [Proxy], _ n: Int) -> [Vec2] {
        var diagonal = [Vec2](repeating: .zero, count: n)
        for t in rest.indices {
            let p = proxies[t], c = rest[t].gram, a = rest[t].area
            let v = corners(patch, t)
            let m = Vec2(p.m00, p.m11)
            diagonal[v.1] += m * (a * c.a)
            diagonal[v.2] += m * (a * c.d)
            diagonal[v.0] += m * (a * (c.a + c.b + c.c + c.d))
        }
        return diagonal
    }

    private static func solve(_ patch: SurfacePatch, _ rest: [Rest], _ proxies: [Proxy], rhs: [Vec2], start: [Vec2]) -> [Vec2] {
        let n = rhs.count
        func dot(_ a: [Vec2], _ b: [Vec2]) -> Double {
            var s = 0.0
            for i in 0..<n { s += a[i].x * b[i].x + a[i].y * b[i].y }
            return s
        }
        func centered(_ x: [Vec2]) -> [Vec2] {
            var mean = Vec2.zero
            for p in x { mean += p }
            mean /= Double(n)
            return x.map { $0 - mean }
        }
        let inverse = diagonal(patch, rest, proxies, n).map { Vec2($0.x > 1e-30 ? 1 / $0.x : 1, $0.y > 1e-30 ? 1 / $0.y : 1) }

        var x = start
        let ax = applyOperator(patch, rest, proxies, x)
        var r = centered((0..<n).map { rhs[$0] - ax[$0] })
        var z = (0..<n).map { r[$0] * inverse[$0] }
        var p = z
        var rz = dot(r, z)
        let target = 1e-14 * max(dot(rhs, rhs), 1e-30)
        for _ in 0..<300 {
            if dot(r, r) < target { break }
            let ap = applyOperator(patch, rest, proxies, p)
            let denominator = dot(p, ap)
            guard denominator > 1e-300 else { break }
            let alpha = rz / denominator
            for i in 0..<n { x[i] += p[i] * alpha; r[i] -= ap[i] * alpha }
            z = (0..<n).map { r[$0] * inverse[$0] }
            let next = dot(r, z)
            let beta = next / max(rz, 1e-300)
            rz = next
            for i in 0..<n { p[i] = z[i] + p[i] * beta }
        }
        return x
    }
}

import Foundation
import simd

/// A recognised geometric primitive and the plush construction it implies.
struct PrimitiveFit: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case sphere, spheroid, cylinder, frustum, cone, capsule
        /// Round cross-sections that narrow monotonically to a tip over a flat or domed base.
        case taperedRevolve
        /// Any other solid of revolution (vases, teardrops, dumbbells).
        case revolve
        case box, pyramid, polyhedron
    }

    let kind: Kind
    /// 0...1. How cleanly the mesh matches the primitive.
    let confidence: Double
    /// Unit symmetry axis (low to high along the axis) for solids of revolution.
    let axis: Vec3?
    let center: Vec3
    /// For tapered shapes: the wide end is at the high end of `axis`.
    let baseAtHigh: Bool
    let faceCount: Int?
    let summary: String

    var isRevolve: Bool { axis != nil }
}

enum PrimitiveDetector {
    /// Largest circularity residual (relative to the largest radius) still accepted as a solid of revolution.
    static let revolveTolerance = 0.035
    /// Share of the surface that must lie on a few flat faces for a mesh to count as a polyhedron.
    static let polyhedronCoverage = 0.7
    static let capNormalCosine = 0.97

    struct Facet {
        var faces: [Int]
        var normal: Vec3
        var area: Double
        var centroid: Vec3
    }

    struct FacetSet {
        var labels: [Int]
        var facets: [Facet]
        /// Share of the surface in clusters that were large enough to count before leftovers were absorbed.
        var coverage: Double
    }

    static func detect(positions: [Vec3], triangles: [Int32]) -> PrimitiveFit? {
        guard positions.count >= 8, triangles.count >= 12, triangles.count.isMultiple(of: 3),
              positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              triangles.allSatisfy({ $0 >= 0 && Int($0) < positions.count }) else { return nil }
        let set = clusterFacets(positions: positions, triangles: triangles)
        if let solid = polyhedronFit(positions: positions, triangles: triangles, set: set) { return solid }
        if let solid = revolveFit(positions: positions, set: set) { return solid }
        if let rounded = roundedBoxFacets(positions: positions, triangles: triangles) {
            return PrimitiveFit(kind: .box, confidence: rounded.coverage, axis: nil, center: positions.reduce(Vec3.zero, +) / Double(positions.count), baseAtHigh: false, faceCount: 6, summary: "Rounded box: 6 broad, gently curved faces in 3 opposite pairs.")
        }
        return nil
    }

    /// Share of the surface that must lean squarely toward one of six box directions for a rounded box.
    static let roundedBoxCoverage = 0.5

    /// Rounded boxes have no truly flat faces, so faces are binned by which of six frame directions their normal favours.
    /// Tries the world axes and the principal axes and keeps the frame that fits best.
    static func roundedBoxFacets(positions: [Vec3], triangles: [Int32]) -> FacetSet? {
        guard !positions.isEmpty, triangles.count >= 12 else { return nil }
        let mean = positions.reduce(Vec3.zero, +) / Double(positions.count)
        let world = [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)]
        var best: FacetSet?
        for frame in [world, principalAxes(of: positions, mean: mean)] where frame.count == 3 {
            var low = Vec3(repeating: .infinity), high = Vec3(repeating: -.infinity)
            for p in positions {
                let q = Vec3(vdot(p, frame[0]), vdot(p, frame[1]), vdot(p, frame[2]))
                low = simd_min(low, q); high = simd_max(high, q)
            }
            let centre = (low + high) / 2, half = (high - low) / 2
            guard half.x > 1e-9, half.y > 1e-9, half.z > 1e-9 else { continue }
            let count = triangles.count / 3
            var labels = [Int](repeating: -1, count: count)
            var members = [[Int]](repeating: [], count: 6)
            var areas = [Double](repeating: 0, count: 6)
            var normals = [Vec3](repeating: .zero, count: 6)
            var centroids = [Vec3](repeating: .zero, count: 6)
            var total = 0.0, aligned = 0.0
            for f in 0..<count {
                let a = positions[Int(triangles[3 * f])], b = positions[Int(triangles[3 * f + 1])], c = positions[Int(triangles[3 * f + 2])]
                let cross = vcross(b - a, c - a)
                let length = vlength(cross)
                guard length > 1e-18 else { continue }
                let area = 0.5 * length
                let n = cross / length
                let local = Vec3(vdot(n, frame[0]), vdot(n, frame[1]), vdot(n, frame[2]))
                let middle = (a + b + c) / 3
                let m = Vec3(vdot(middle, frame[0]), vdot(middle, frame[1]), vdot(middle, frame[2]))
                let axisIndex = abs(local.x) >= abs(local.y) && abs(local.x) >= abs(local.z) ? 0 : (abs(local.y) >= abs(local.z) ? 1 : 2)
                let side = local[axisIndex] >= 0 ? 0 : 1
                let label = axisIndex * 2 + side
                labels[f] = label; members[label].append(f)
                areas[label] += area; normals[label] += n * area; centroids[label] += middle * area
                total += area
                let reach = abs(m[axisIndex] - centre[axisIndex]) / half[axisIndex]
                if abs(local[axisIndex]) >= 0.9, reach >= 0.85 { aligned += area }
            }
            guard total > 0, areas.allSatisfy({ $0 >= 0.05 * total }) else { continue }
            let coverage = aligned / total
            guard coverage >= roundedBoxCoverage, coverage > (best?.coverage ?? 0) else { continue }
            let facets = (0..<6).map { id -> Facet in
                let n = normals[id] / areas[id]
                return Facet(faces: members[id], normal: n / max(vlength(n), 1e-12), area: areas[id], centroid: centroids[id] / areas[id])
            }
            best = FacetSet(labels: labels, facets: facets, coverage: coverage)
        }
        return best
    }

    // MARK: Planar facets

    static func clusterFacets(positions: [Vec3], triangles: [Int32], toleranceDegrees: Double = 8, minimumShare: Double = 0.025) -> FacetSet {
        let count = triangles.count / 3
        var normal = [Vec3](repeating: .zero, count: count)
        var area = [Double](repeating: 0, count: count)
        var centroid = [Vec3](repeating: .zero, count: count)
        var low = positions[0], high = positions[0]
        for p in positions { low = Vec3(min(low.x, p.x), min(low.y, p.y), min(low.z, p.z)); high = Vec3(max(high.x, p.x), max(high.y, p.y), max(high.z, p.z)) }
        let diagonal = vlength(high - low)
        for f in 0..<count {
            let a = positions[Int(triangles[3 * f])], b = positions[Int(triangles[3 * f + 1])], c = positions[Int(triangles[3 * f + 2])]
            let cross = vcross(b - a, c - a)
            let length = vlength(cross)
            area[f] = 0.5 * length
            normal[f] = length > 1e-18 ? cross / length : .zero
            centroid[f] = (a + b + c) / 3
        }
        let total = area.reduce(0, +)
        guard total > 0, diagonal > 0 else { return FacetSet(labels: [Int](repeating: -1, count: count), facets: [], coverage: 0) }

        var edgeFaces: [UInt64: [Int]] = [:]
        for f in 0..<count {
            for k in 0..<3 {
                let a = triangles[3 * f + k], b = triangles[3 * f + (k + 1) % 3]
                edgeFaces[SurfaceCutter.edgeKey(a, b), default: []].append(f)
            }
        }
        var neighbors = [[Int]](repeating: [], count: count)
        for faces in edgeFaces.values where faces.count == 2 {
            neighbors[faces[0]].append(faces[1]); neighbors[faces[1]].append(faces[0])
        }

        // Seed from the flattest regions so a seed never starts on a rounded edge.
        let flatness: [Double] = (0..<count).map { f in neighbors[f].map { vdot(normal[f], normal[$0]) }.min() ?? 1 }
        let order = (0..<count).sorted { flatness[$0] != flatness[$1] ? flatness[$0] > flatness[$1] : area[$0] > area[$1] }
        let cosine = cos(toleranceDegrees * .pi / 180)
        let planeTolerance = 0.008 * diagonal
        var cluster = [Int](repeating: -1, count: count)
        var clusters: [[Int]] = []
        for seed in order where cluster[seed] < 0 && area[seed] > 0 {
            let id = clusters.count
            let seedNormal = normal[seed], seedPoint = centroid[seed]
            var members = [seed]
            cluster[seed] = id
            var queue = [seed], head = 0
            while head < queue.count {
                let f = queue[head]; head += 1
                for g in neighbors[f] where cluster[g] < 0 && area[g] > 0 {
                    guard vdot(normal[g], seedNormal) >= cosine, abs(vdot(centroid[g] - seedPoint, seedNormal)) <= planeTolerance else { continue }
                    cluster[g] = id
                    members.append(g)
                    queue.append(g)
                }
            }
            clusters.append(members)
        }

        let significant = clusters.filter { $0.reduce(0) { $0 + area[$1] } >= minimumShare * total }
            .sorted { $0.reduce(0) { $0 + area[$1] } > $1.reduce(0) { $0 + area[$1] } }
        let coverage = significant.reduce(0.0) { $0 + $1.reduce(0) { $0 + area[$1] } } / total

        var labels = [Int](repeating: -1, count: count)
        var queue: [Int] = []
        for (id, members) in significant.enumerated() { for f in members { labels[f] = id; queue.append(f) } }
        var head = 0
        while head < queue.count {
            let f = queue[head]; head += 1
            for g in neighbors[f] where labels[g] < 0 { labels[g] = labels[f]; queue.append(g) }
        }
        var facets: [Facet] = []
        for id in significant.indices {
            let faces = (0..<count).filter { labels[$0] == id }
            let faceArea = faces.reduce(0) { $0 + area[$1] }
            guard faceArea > 0 else { continue }
            let n = faces.reduce(Vec3.zero) { $0 + normal[$1] * area[$1] } / faceArea
            let c = faces.reduce(Vec3.zero) { $0 + centroid[$1] * area[$1] } / faceArea
            facets.append(Facet(faces: faces, normal: n / max(vlength(n), 1e-12), area: faceArea, centroid: c))
        }
        return FacetSet(labels: labels, facets: facets, coverage: coverage)
    }

    private static func polyhedronFit(positions: [Vec3], triangles: [Int32], set: FacetSet) -> PrimitiveFit? {
        let facets = set.facets
        guard (4...14).contains(facets.count), set.coverage >= polyhedronCoverage else { return nil }
        let centre = positions.reduce(Vec3.zero, +) / Double(positions.count)
        var low = positions[0], high = positions[0]
        for p in positions { low = Vec3(min(low.x, p.x), min(low.y, p.y), min(low.z, p.z)); high = Vec3(max(high.x, p.x), max(high.y, p.y), max(high.z, p.z)) }
        let diagonal = vlength(high - low)

        if facets.count == 6 {
            let opposite = facets.indices.map { i in facets.indices.first { $0 != i && vdot(facets[i].normal, facets[$0].normal) < -0.95 } }
            if opposite.allSatisfy({ $0 != nil }) {
                let orthogonal = facets.allSatisfy { a in facets.allSatisfy { b in abs(vdot(a.normal, b.normal)) < 0.2 || abs(vdot(a.normal, b.normal)) > 0.95 } }
                if orthogonal {
                    return PrimitiveFit(kind: .box, confidence: set.coverage, axis: nil, center: centre, baseAtHigh: false, faceCount: 6, summary: "Box: 6 flat faces in 3 opposite pairs.")
                }
            }
        }
        if let base = facets.max(by: { $0.area < $1.area }), facets.count >= 4 {
            let planePoint = base.centroid
            var apex = positions[0], farthest = -Double.infinity
            for p in positions {
                let d = abs(vdot(p - planePoint, base.normal))
                if d > farthest { farthest = d; apex = p }
            }
            let sides = facets.filter { $0.centroid != base.centroid }
            let meeting = sides.filter { side in
                side.faces.contains { f in (0..<3).contains { k in vlength(positions[Int(triangles[3 * f + k])] - apex) < 0.06 * diagonal } }
            }
            if sides.count >= 3, meeting.count == sides.count, sides.allSatisfy({ abs(vdot($0.normal, base.normal)) < 0.98 }) {
                return PrimitiveFit(kind: .pyramid, confidence: set.coverage, axis: nil, center: centre, baseAtHigh: false, faceCount: facets.count, summary: "Pyramid: a flat base and \(sides.count) faces meeting at the apex.")
            }
        }
        return PrimitiveFit(kind: .polyhedron, confidence: set.coverage, axis: nil, center: centre, baseAtHigh: false, faceCount: facets.count, summary: "Faceted solid with \(facets.count) flat faces.")
    }

    // MARK: Solids of revolution

    /// Principal axes of the vertex cloud via cyclic Jacobi rotations on the covariance matrix.
    static func principalAxes(of positions: [Vec3], mean: Vec3) -> [Vec3] {
        var m = [[Double]](repeating: [0, 0, 0], count: 3)
        for p in positions {
            let d = [p.x - mean.x, p.y - mean.y, p.z - mean.z]
            for i in 0..<3 { for j in 0..<3 { m[i][j] += d[i] * d[j] } }
        }
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<40 {
            var off = 0.0
            for (p, q) in [(0, 1), (0, 2), (1, 2)] {
                off += m[p][q] * m[p][q]
                guard abs(m[p][q]) > 1e-18 else { continue }
                let theta = (m[q][q] - m[p][p]) / (2 * m[p][q])
                let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                let c = 1 / (t * t + 1).squareRoot(), s = t * c
                for k in 0..<3 {
                    let kp = m[k][p], kq = m[k][q]
                    m[k][p] = c * kp - s * kq; m[k][q] = s * kp + c * kq
                }
                for k in 0..<3 {
                    let pk = m[p][k], qk = m[q][k]
                    m[p][k] = c * pk - s * qk; m[q][k] = s * pk + c * qk
                }
                for k in 0..<3 {
                    let kp = v[k][p], kq = v[k][q]
                    v[k][p] = c * kp - s * kq; v[k][q] = s * kp + c * kq
                }
            }
            if off < 1e-24 { break }
        }
        return (0..<3).map { Vec3(v[0][$0], v[1][$0], v[2][$0]) }
    }

    private struct Profile {
        let score: Double
        let axis: Vec3
        let low: Double
        let span: Double
        let maxRadius: Double
        /// (position 0...1 along the axis, radius / maxRadius) for interior bins.
        let samples: [(t: Double, r: Double)]
        let lowEndRadius: Double
        let highEndRadius: Double
    }

    private static func profile(positions: [Vec3], mean: Vec3, axis: Vec3) -> Profile? {
        let bins = 24
        var t = [Double](repeating: 0, count: positions.count), r = t
        for (i, p) in positions.enumerated() {
            let d = p - mean
            t[i] = vdot(d, axis)
            r[i] = vlength(d - axis * t[i])
        }
        guard let tMin = t.min(), let tMax = t.max(), tMax - tMin > 0, let rMax = r.max(), rMax > 0 else { return nil }
        let span = tMax - tMin
        func bin(_ value: Double) -> Int { min(bins - 1, Int((value - tMin) / span * Double(bins))) }
        var members = [[Int]](repeating: [], count: bins)
        for i in positions.indices { members[bin(t[i])].append(i) }
        var residual = 0.0, weight = 0.0, outliers = 0.0
        var samples: [(t: Double, r: Double)] = []
        for b in 1..<(bins - 1) where members[b].count >= 4 {
            let ids = members[b]
            let n = Double(ids.count)
            let mt = ids.reduce(0) { $0 + t[$1] } / n, mr = ids.reduce(0) { $0 + r[$1] } / n
            var stt = 0.0, str = 0.0
            for i in ids { stt += (t[i] - mt) * (t[i] - mt); str += (t[i] - mt) * (r[i] - mr) }
            let slope = stt > 1e-18 ? str / stt : 0
            for i in ids { let e = r[i] - (mr + slope * (t[i] - mt)); residual += e * e; if abs(e) > 0.05 * rMax { outliers += 1 } }
            weight += n
            samples.append((((mt - tMin) / span), mr / rMax))
        }
        // A rounded box has a modest RMS error but many vertices far from any circle.
        guard weight > 0, samples.count >= 6, outliers / weight < 0.03 else { return nil }
        let score = (residual / weight).squareRoot() / rMax
        let lowEnd = zip(t, r).filter { $0.0 < tMin + 0.03 * span }.map(\.1).max() ?? 0
        let highEnd = zip(t, r).filter { $0.0 > tMax - 0.03 * span }.map(\.1).max() ?? 0
        return Profile(score: score, axis: axis, low: tMin, span: span, maxRadius: rMax, samples: samples, lowEndRadius: lowEnd / rMax, highEndRadius: highEnd / rMax)
    }

    private static func revolveFit(positions: [Vec3], set: FacetSet) -> PrimitiveFit? {
        let mean = positions.reduce(Vec3.zero, +) / Double(positions.count)
        let candidates = principalAxes(of: positions, mean: mean).compactMap { profile(positions: positions, mean: mean, axis: $0) }
        guard let best = candidates.min(by: { $0.score < $1.score }), best.score < revolveTolerance else { return nil }
        let confidence = max(0, 1 - best.score / revolveTolerance)
        // Rounded boxes score around 0.55; true solids of revolution score above 0.9.
        guard confidence >= 0.85 else { return nil }
        let axis = best.axis
        let samples = best.samples

        func hasCap(atHigh: Bool) -> Bool {
            set.facets.contains { facet in
                guard abs(vdot(facet.normal, axis)) > capNormalCosine, facet.area > 0 else { return false }
                let u = (vdot(facet.centroid - mean, axis) - best.low) / best.span
                return atHigh ? u > 0.96 : u < 0.04
            }
        }
        let capLow = hasCap(atHigh: false), capHigh = hasCap(atHigh: true)
        let radii = samples.map(\.r)
        let meanRadius = radii.reduce(0, +) / Double(radii.count)
        let spread = (radii.reduce(0) { $0 + ($1 - meanRadius) * ($1 - meanRadius) } / Double(radii.count)).squareRoot()
        let linearResidual: Double = {
            let n = Double(samples.count)
            let mt = samples.reduce(0) { $0 + $1.t } / n
            var stt = 0.0, str = 0.0
            for s in samples { stt += (s.t - mt) * (s.t - mt); str += (s.t - mt) * (s.r - meanRadius) }
            let slope = stt > 0 ? str / stt : 0
            return (samples.reduce(0) { $0 + pow($1.r - (meanRadius + slope * ($1.t - mt)), 2) } / n).squareRoot()
        }()
        let ellipseError = (samples.reduce(0) { total, s in
            let u = 2 * s.t - 1
            return total + pow(s.r - (1 - u * u).squareRoot(), 2)
        } / Double(samples.count)).squareRoot()
        let middle = samples.filter { (0.3...0.7).contains($0.t) }.map(\.r)
        let plateau = !middle.isEmpty && middle.allSatisfy { $0 >= 0.94 }
        let aspect = best.span / (2 * best.maxRadius)
        let lowEnd = best.lowEndRadius, highEnd = best.highEndRadius

        func fit(_ kind: PrimitiveFit.Kind, baseAtHigh: Bool = false, _ summary: String) -> PrimitiveFit {
            PrimitiveFit(kind: kind, confidence: confidence, axis: axis, center: mean, baseAtHigh: baseAtHigh, faceCount: nil, summary: summary)
        }
        if capLow, capHigh, spread < 0.05, radii.min() ?? 0 > 0.93 {
            return fit(.cylinder, String(format: "Cylinder: round, constant radius, two flat ends (height/diameter %.2f).", aspect))
        }
        if capLow, capHigh, linearResidual < 0.04, abs(lowEnd - highEnd) > 0.1 {
            return fit(.frustum, baseAtHigh: highEnd > lowEnd, "Truncated cone: two flat ends of different radius.")
        }
        if capLow != capHigh, linearResidual < 0.05, (capHigh ? lowEnd : highEnd) < 0.12 {
            return fit(.cone, baseAtHigh: capHigh, String(format: "Cone: flat circular base narrowing to a point (height/diameter %.2f).", aspect))
        }
        if !capLow, !capHigh, plateau, lowEnd < 0.5, highEnd < 0.5 {
            return fit(.capsule, String(format: "Capsule: straight round body with two domed ends (length/diameter %.2f).", aspect))
        }
        if !capLow, !capHigh, ellipseError < 0.07 {
            return abs(aspect - 1) < 0.1
                ? fit(.sphere, "Sphere: constant radius in every direction.")
                : fit(.spheroid, String(format: "Spheroid: a stretched sphere (length/diameter %.2f).", aspect))
        }
        let baseSide = lowEnd >= highEnd ? radii.prefix(radii.count / 2) : radii.suffix(radii.count / 2)
        let ordered = lowEnd >= highEnd ? radii : Array(radii.reversed())
        let narrowing = zip(ordered, ordered.dropFirst()).allSatisfy { $1 <= $0 * 1.15 }
        if narrowing, (lowEnd >= highEnd ? highEnd : lowEnd) < 0.4, !baseSide.isEmpty, capLow || capHigh {
            return fit(.taperedRevolve, baseAtHigh: highEnd > lowEnd, "Round shape narrowing steadily from a base to a tip.")
        }
        return fit(.revolve, "Solid of revolution (round cross-sections about one axis).")
    }

    // MARK: Alignment

    /// Rotates `positions` about `center` so that `axis` points along +Y. The rotation preserves every length and area.
    static func align(_ positions: [Vec3], axis: Vec3, center: Vec3) -> [Vec3] {
        let from = axis / max(vlength(axis), 1e-12), to = Vec3(0, 1, 0)
        let c = vdot(from, to)
        if c > 1 - 1e-12 { return positions }
        let v: Vec3 = c < -1 + 1e-12 ? Vec3(1, 0, 0) : vcross(from, to)
        let s = c < -1 + 1e-12 ? 0.0 : vlength(v)
        let k = c < -1 + 1e-12 ? v : v / s
        let angle = c < -1 + 1e-12 ? Double.pi : atan2(s, c)
        let (sa, ca) = (sin(angle), cos(angle))
        return positions.map { p in
            let d = p - center
            return center + d * ca + vcross(k, d) * sa + k * (vdot(k, d) * (1 - ca))
        }
    }
}

import Foundation

/// Identifies pattern pieces that are the same shape (rotated and/or mirrored), so each is drawn once.
enum PieceCongruence {
    struct Member: Sendable, Equatable {
        let island: Int
        /// True when this piece is the mirror image of the group's representative.
        let mirrored: Bool
    }

    struct Group: Sendable, Equatable {
        let representative: Int
        let members: [Member]
        var copies: Int { members.count }
        var mirroredCopies: Int { members.filter(\.mirrored).count }
    }

    static let sampleCount = 96

    /// Groups islands in index order; every island belongs to exactly one group. Islands whose outline
    /// cannot be extracted stay alone.
    static func groups(for result: FlatteningResult, tolerance: Double = 0.03) -> [Group] {
        struct Signature {
            let profile: [Double]
            let area: Double
            let perimeter: Double
        }
        let signatures: [Signature?] = result.islands.map { island in
            guard let loop = try? PatternGeometry.boundaryLoop(of: island), let sampled = resample(loop, count: sampleCount) else { return nil }
            return Signature(profile: sampled.profile, area: sampled.area, perimeter: sampled.perimeter)
        }

        var groups: [(representative: Int, members: [Member])] = []
        for index in result.islands.indices {
            guard let signature = signatures[index] else {
                groups.append((index, [Member(island: index, mirrored: false)]))
                continue
            }
            var placed = false
            for g in groups.indices {
                let r = groups[g].representative
                guard let other = signatures[r] else { continue }
                guard relativeDifference(signature.area, other.area) <= 2 * tolerance,
                      relativeDifference(signature.perimeter, other.perimeter) <= 2 * tolerance else { continue }
                let scale = other.area.squareRoot()
                if cyclicDistance(signature.profile, other.profile) / scale <= tolerance {
                    groups[g].members.append(Member(island: index, mirrored: false))
                    placed = true
                } else if cyclicDistance(signature.profile.reversed(), other.profile) / scale <= tolerance {
                    groups[g].members.append(Member(island: index, mirrored: true))
                    placed = true
                }
                if placed { break }
            }
            if !placed { groups.append((index, [Member(island: index, mirrored: false)])) }
        }
        return groups.map { Group(representative: $0.representative, members: $0.members) }
    }

    private static func relativeDifference(_ a: Double, _ b: Double) -> Double {
        let m = max(abs(a), abs(b))
        return m > 0 ? abs(a - b) / m : 0
    }

    /// Smallest max-norm difference between `a` and any cyclic shift of `b`.
    private static func cyclicDistance(_ a: [Double], _ b: [Double]) -> Double {
        let n = a.count
        var best = Double.infinity
        for shift in 0..<n {
            var worst = 0.0
            for i in 0..<n {
                worst = max(worst, abs(a[i] - b[(i + shift) % n]))
                if worst >= best { break }
            }
            best = min(best, worst)
        }
        return best
    }

    /// Centroid-distance profile of the outline at equal arc-length steps, plus its area and perimeter.
    private static func resample(_ loop: [Vec2], count: Int) -> (profile: [Double], area: Double, perimeter: Double)? {
        guard loop.count >= 3 else { return nil }
        var perimeter = 0.0, area2 = 0.0
        var centroid = Vec2.zero
        for i in loop.indices {
            let a = loop[i], b = loop[(i + 1) % loop.count]
            let cross = a.x * b.y - b.x * a.y
            area2 += cross
            centroid += (a + b) * cross
            perimeter += vlength(b - a)
        }
        guard abs(area2) > 1e-18, perimeter > 0 else { return nil }
        centroid /= 3 * area2

        var profile: [Double] = []
        profile.reserveCapacity(count)
        var edge = 0, walked = 0.0
        for k in 0..<count {
            let target = perimeter * Double(k) / Double(count)
            while edge < loop.count {
                let length = vlength(loop[(edge + 1) % loop.count] - loop[edge])
                if walked + length >= target { break }
                walked += length
                edge += 1
            }
            let a = loop[min(edge, loop.count - 1)], b = loop[(min(edge, loop.count - 1) + 1) % loop.count]
            let length = vlength(b - a)
            let t = length > 0 ? (target - walked) / length : 0
            profile.append(vlength(a + (b - a) * t - centroid))
        }
        return (profile, abs(area2) / 2, perimeter)
    }
}

/// A run of boundary edges of an island that is sewn to one other piece.
struct SeamSection: Sendable, Equatable {
    /// Index range into the island's boundary index loop: edges `start ..< start + count` (cyclic).
    let start: Int
    let count: Int
    /// Island index of the piece to sew to. Equal to the island itself for a dart; nil for an open mesh edge.
    let partner: Int?
}

enum SeamSections {
    /// Boundary sections of every island, in boundary-loop order, split wherever the partner piece changes.
    static func sections(for result: FlatteningResult) -> [[SeamSection]] {
        func key(_ a: Int, _ b: Int) -> UInt64 { UInt64(min(a, b)) << 32 | UInt64(max(a, b)) }

        let loops: [[Int32]?] = result.islands.map { try? PatternGeometry.boundaryIndices(of: $0) }
        var owners: [UInt64: [Int]] = [:]
        for (index, island) in result.islands.enumerated() {
            guard let loop = loops[index] else { continue }
            for i in loop.indices {
                let a = island.sourceVertex[Int(loop[i])], b = island.sourceVertex[Int(loop[(i + 1) % loop.count])]
                owners[key(a, b), default: []].append(index)
            }
        }

        return result.islands.indices.map { index in
            guard let loop = loops[index] else { return [] }
            let island = result.islands[index]
            let partners: [Int?] = loop.indices.map { i in
                let a = island.sourceVertex[Int(loop[i])], b = island.sourceVertex[Int(loop[(i + 1) % loop.count])]
                let others = owners[key(a, b)] ?? []
                if let other = others.first(where: { $0 != index }) { return other }
                return others.count >= 2 ? index : nil
            }
            return runs(partners)
        }
    }

    private static func runs(_ partners: [Int?]) -> [SeamSection] {
        let n = partners.count
        guard n > 0 else { return [] }
        // Start at a change point so a run is never split across the cyclic origin.
        let origin = (0..<n).first { partners[$0] != partners[($0 + n - 1) % n] } ?? 0
        var result: [SeamSection] = []
        var start = origin, length = 1
        for step in 1..<max(n, 1) {
            let i = (origin + step) % n
            if partners[i] == partners[start % n] {
                length += 1
            } else {
                result.append(SeamSection(start: start, count: length, partner: partners[start % n]))
                start = i
                length = 1
            }
        }
        result.append(SeamSection(start: start, count: length, partner: partners[start % n]))
        return result
    }
}

/// Maps a 3D detail (an eye, nose, or applique) onto the flat piece that carries it.
enum DetailPlacement {
    struct Located: Sendable, Equatable {
        let island: Int
        let uv: Vec2
        /// Rotation (radians, island UV space) that carries the 3D `up` direction onto the flat piece.
        let rotation: Double
        /// Island units per 3D unit at this spot.
        let scale: Double
        /// Distance from the requested point to the surface.
        let distance: Double
    }

    static func locate(point: Vec3, up: Vec3, in result: FlatteningResult, positions: [Vec3]) -> Located? {
        var best: (distance: Double, located: Located)?
        for island in result.islands {
            for t in 0..<(island.triangles.count / 3) {
                let ia = Int(island.triangles[t * 3]), ib = Int(island.triangles[t * 3 + 1]), ic = Int(island.triangles[t * 3 + 2])
                let a = positions[island.sourceVertex[ia]], b = positions[island.sourceVertex[ib]], c = positions[island.sourceVertex[ic]]
                guard let hit = closest(point, a, b, c), best == nil || hit.distance < best!.distance else { continue }
                let uv = island.uv[ia] * hit.weights.x + island.uv[ib] * hit.weights.y + island.uv[ic] * hit.weights.z

                let e1 = b - a, e2 = c - a
                let normal = vcross(e1, e2)
                let area3D = 0.5 * vlength(normal)
                let u1 = island.uv[ib] - island.uv[ia], u2 = island.uv[ic] - island.uv[ia]
                let area2D = 0.5 * abs(u1.x * u2.y - u1.y * u2.x)
                // Express the up direction in the triangle's edge basis, then carry it over to UV space.
                let tangentUp = up - normal * (vdot(up, normal) / vdot(normal, normal))
                let g11 = vdot(e1, e1), g12 = vdot(e1, e2), g22 = vdot(e2, e2)
                let determinant = g11 * g22 - g12 * g12
                guard determinant > 1e-18 else { continue }
                let r1 = vdot(tangentUp, e1), r2 = vdot(tangentUp, e2)
                let s = (r1 * g22 - r2 * g12) / determinant
                let u = (r2 * g11 - r1 * g12) / determinant
                let mapped = u1 * s + u2 * u
                let rotation = vlength(mapped) > 1e-18 ? atan2(mapped.y, mapped.x) - Double.pi / 2 : 0
                let scale = area3D > 0 ? (area2D / area3D).squareRoot() : 1
                best = (hit.distance, Located(island: island.segmentIndex, uv: uv, rotation: rotation, scale: scale, distance: hit.distance))
            }
        }
        return best?.located
    }

    /// Closest point on a triangle with its barycentric weights.
    private static func closest(_ p: Vec3, _ a: Vec3, _ b: Vec3, _ c: Vec3) -> (distance: Double, weights: Vec3)? {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = vdot(ab, ap), d2 = vdot(ac, ap)
        func result(_ w: Vec3) -> (Double, Vec3) {
            (vlength(p - (a * w.x + b * w.y + c * w.z)), w)
        }
        if d1 <= 0, d2 <= 0 { return result(Vec3(1, 0, 0)) }
        let bp = p - b
        let d3 = vdot(ab, bp), d4 = vdot(ac, bp)
        if d3 >= 0, d4 <= d3 { return result(Vec3(0, 1, 0)) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 {
            let v = d1 / (d1 - d3)
            return result(Vec3(1 - v, v, 0))
        }
        let cp = p - c
        let d5 = vdot(ab, cp), d6 = vdot(ac, cp)
        if d6 >= 0, d5 <= d6 { return result(Vec3(0, 0, 1)) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 {
            let w = d2 / (d2 - d6)
            return result(Vec3(1 - w, 0, w))
        }
        let va = d3 * d6 - d5 * d4
        if va <= 0, d4 - d3 >= 0, d5 - d6 >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return result(Vec3(0, 1 - w, w))
        }
        let denominator = va + vb + vc
        guard abs(denominator) > 1e-300 else { return nil }
        let v = vb / denominator, w = vc / denominator
        return result(Vec3(1 - v - w, v, w))
    }
}

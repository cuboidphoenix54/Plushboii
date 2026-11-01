import Foundation

/// Checks and normalizes a mesh before seams are placed: size limits, which way is up, and left/right symmetry.
enum ModelPreparation {
    static let recommendedVertices = 10_000
    static let hardFaceLimit = 100_000

    struct Budget: Sendable, Equatable {
        enum Level: Sendable, Equatable { case ok, large, needsSimplification }
        let level: Level
        let message: String?
    }

    static func assess(vertexCount: Int, faceCount: Int) -> Budget {
        if faceCount > hardFaceLimit {
            return Budget(level: .needsSimplification, message: "\(faceCount) faces exceeds the \(hardFaceLimit)-face limit. Simplify the mesh before cutting; detail beyond this cannot be sewn.")
        }
        if vertexCount > recommendedVertices {
            return Budget(level: .large, message: "\(vertexCount) vertices is above the recommended \(recommendedVertices). Seam editing and flattening will be slow; consider simplifying.")
        }
        return Budget(level: .ok, message: nil)
    }

    // MARK: Orientation

    struct OrientationCandidate: Sendable, Equatable {
        /// Direction in the model's coordinates that would point up.
        let up: Vec3
        /// Larger is a steadier resting pose.
        let score: Double
        let centerOfMassSupported: Bool
    }

    /// Ranks the six axis directions by how stably the mesh would rest on its lowest face.
    static func orientationCandidates(positions: [Vec3]) -> [OrientationCandidate] {
        guard positions.count >= 3 else { return [] }
        let center = positions.reduce(Vec3.zero, +) / Double(positions.count)
        let axes: [Vec3] = [Vec3(0, 1, 0), Vec3(0, -1, 0), Vec3(1, 0, 0), Vec3(-1, 0, 0), Vec3(0, 0, 1), Vec3(0, 0, -1)]
        return axes.map { up in
            let heights = positions.map { vdot($0, up) }
            let low = heights.min()!, high = heights.max()!
            let extent = high - low
            guard extent > 0 else { return OrientationCandidate(up: up, score: 0, centerOfMassSupported: false) }
            let band = low + 0.03 * extent
            let (u, v) = basis(for: up)
            let footprint = positions.indices.filter { heights[$0] <= band }.map { Vec2(vdot(positions[$0], u), vdot(positions[$0], v)) }
            let hull = convexHull(footprint)
            let supported = contains(hull, Vec2(vdot(center, u), vdot(center, v)))
            // Footprint relative to height: wide, short rests beat tall, narrow ones.
            let score = polygonArea(hull) / (extent * extent) + (supported ? 0.25 : 0)
            return OrientationCandidate(up: up, score: score, centerOfMassSupported: supported)
        }.sorted { $0.score > $1.score }
    }

    /// Rotates so `up` becomes +Y, then turns the model `quarterTurns` quarter turns about +Y.
    static func oriented(_ positions: [Vec3], up: Vec3, quarterTurns: Int = 0) -> [Vec3] {
        let target = Vec3(0, 1, 0)
        let u = up / vlength(up)
        let axis = vcross(u, target)
        let sine = vlength(axis), cosine = vdot(u, target)
        var rotate: (Vec3) -> Vec3 = { $0 }
        if sine > 1e-12 {
            let k = axis / sine
            rotate = { p in p * cosine + vcross(k, p) * sine + k * (vdot(k, p) * (1 - cosine)) }
        } else if cosine < 0 {
            rotate = { Vec3($0.x, -$0.y, -$0.z) }
        }
        let angle = Double(quarterTurns) * Double.pi / 2
        let c = cos(angle), s = sin(angle)
        return positions.map {
            let p = rotate($0)
            return Vec3(p.x * c + p.z * s, p.y, -p.x * s + p.z * c)
        }
    }

    private static func basis(for up: Vec3) -> (Vec3, Vec3) {
        let helper = abs(up.x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)
        let u = vcross(up, helper)
        let un = u / vlength(u)
        return (un, vcross(up, un))
    }

    private static func convexHull(_ points: [Vec2]) -> [Vec2] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count >= 3 else { return sorted }
        func cross(_ o: Vec2, _ a: Vec2, _ b: Vec2) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var hull: [Vec2] = []
        for p in sorted {
            while hull.count >= 2, cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 { hull.removeLast() }
            hull.append(p)
        }
        let lowerCount = hull.count + 1
        for p in sorted.reversed().dropFirst() {
            while hull.count >= lowerCount, cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 { hull.removeLast() }
            hull.append(p)
        }
        hull.removeLast()
        return hull
    }

    private static func polygonArea(_ polygon: [Vec2]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        var total = 0.0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            total += a.x * b.y - b.x * a.y
        }
        return abs(total) / 2
    }

    /// Point-in-convex-polygon for a counter-clockwise hull.
    private static func contains(_ hull: [Vec2], _ p: Vec2) -> Bool {
        guard hull.count >= 3 else { return false }
        for i in hull.indices {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            if (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) < 0 { return false }
        }
        return true
    }

    // MARK: Symmetry

    struct MirrorMap: Sendable, Equatable {
        /// 0 = x, 1 = y, 2 = z: the axis that is flipped.
        let axis: Int
        let planeCoordinate: Double
        /// Mirror partner of each vertex, or -1 when no vertex lies within tolerance.
        let partner: [Int]
        let matchedFraction: Double

        func mirror(_ path: [Int]) -> [Int]? {
            let mapped = path.map { partner.indices.contains($0) ? partner[$0] : -1 }
            return mapped.contains(-1) ? nil : mapped
        }
    }

    /// Finds the best mirror plane perpendicular to a coordinate axis. Returns nil when no axis matches well.
    static func detectMirror(positions: [Vec3], minimumMatch: Double = 0.9) -> MirrorMap? {
        guard positions.count >= 4 else { return nil }
        var low = positions[0], high = positions[0]
        for p in positions {
            low = Vec3(min(low.x, p.x), min(low.y, p.y), min(low.z, p.z))
            high = Vec3(max(high.x, p.x), max(high.y, p.y), max(high.z, p.z))
        }
        let diagonal = vlength(high - low)
        guard diagonal > 0, diagonal.isFinite else { return nil }
        let tolerance = diagonal * 0.01
        let cell = tolerance * 2

        struct Cell: Hashable { let x: Int, y: Int, z: Int }
        func cellOf(_ p: Vec3) -> Cell {
            Cell(x: Int((p.x / cell).rounded(.down)), y: Int((p.y / cell).rounded(.down)), z: Int((p.z / cell).rounded(.down)))
        }
        var grid: [Cell: [Int]] = [:]
        for (i, p) in positions.enumerated() { grid[cellOf(p), default: []].append(i) }

        var best: MirrorMap?
        for axis in 0..<3 {
            let plane = (low[axis] + high[axis]) / 2
            var partner = [Int](repeating: -1, count: positions.count)
            var matched = 0
            for (i, p) in positions.enumerated() {
                var reflected = p
                reflected[axis] = 2 * plane - p[axis]
                let home = cellOf(reflected)
                var nearest = -1, nearestDistance = tolerance
                for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
                    guard let bucket = grid[Cell(x: home.x + dx, y: home.y + dy, z: home.z + dz)] else { continue }
                    for j in bucket {
                        let d = vlength(positions[j] - reflected)
                        if d < nearestDistance || (d == nearestDistance && nearest == -1) { nearest = j; nearestDistance = d }
                    }
                } } }
                if nearest >= 0 { partner[i] = nearest; matched += 1 }
            }
            let fraction = Double(matched) / Double(positions.count)
            if fraction >= minimumMatch, fraction > (best?.matchedFraction ?? 0) {
                best = MirrorMap(axis: axis, planeCoordinate: plane, partner: partner, matchedFraction: fraction)
            }
        }
        return best
    }
}

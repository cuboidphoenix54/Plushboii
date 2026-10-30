import Foundation

/// Cubic Bezier in sheet space. Pure value math so it is identical on every platform and unit-testable;
/// `PatternRenderer` converts it to `CGPath` (`move(to:)`, `addCurve(to:control1:control2:)`) at the Apple boundary.
struct BezierSegment: Sendable, Equatable {
    var p0: Vec2
    var c1: Vec2
    var c2: Vec2
    var p3: Vec2

    static func line(_ a: Vec2, _ b: Vec2) -> BezierSegment {
        let d: Vec2 = b - a
        return BezierSegment(p0: a, c1: a + d / 3, c2: a + d * (2.0 / 3.0), p3: b)
    }

    func point(at t: Double) -> Vec2 {
        let u = 1 - t
        let w0: Double = u * u * u, w1: Double = 3 * u * u * t
        let w2: Double = 3 * u * t * t, w3: Double = t * t * t
        let a: Vec2 = p0 * w0 + c1 * w1
        let b: Vec2 = c2 * w2 + p3 * w3
        return a + b
    }

    func derivative(at t: Double) -> Vec2 {
        let u = 1 - t
        let w0: Double = 3 * u * u, w1: Double = 6 * u * t, w2: Double = 3 * t * t
        let a: Vec2 = (c1 - p0) * w0
        let b: Vec2 = (c2 - c1) * w1
        let c: Vec2 = (p3 - c2) * w2
        return a + b + c
    }

    func secondDerivative(at t: Double) -> Vec2 {
        let a: Vec2 = (c2 - c1 * 2 + p0) * (6 * (1 - t))
        let b: Vec2 = (p3 - c2 * 2 + c1) * (6 * t)
        return a + b
    }

    func split(at t: Double) -> (BezierSegment, BezierSegment) {
        let a = p0 + (c1 - p0) * t, b = c1 + (c2 - c1) * t, c = c2 + (p3 - c2) * t
        let d = a + (b - a) * t, e = b + (c - b) * t
        let m = d + (e - d) * t
        return (BezierSegment(p0: p0, c1: a, c2: d, p3: m), BezierSegment(p0: m, c1: e, c2: c, p3: p3))
    }

    /// Conservative bounds from the control polygon (a Bezier never leaves its convex hull).
    var controlBounds: Rect2 {
        let xs = [p0.x, c1.x, c2.x, p3.x], ys = [p0.y, c1.y, c2.y, p3.y]
        return Rect2(minX: xs.min()!, minY: ys.min()!, maxX: xs.max()!, maxY: ys.max()!)
    }

    func mapped(_ transform: (Vec2) -> Vec2) -> BezierSegment {
        BezierSegment(p0: transform(p0), c1: transform(c1), c2: transform(c2), p3: transform(p3))
    }
}

struct Rect2: Sendable, Equatable {
    var minX: Double, minY: Double, maxX: Double, maxY: Double
    var width: Double { maxX - minX }
    var height: Double { maxY - minY }

    func union(_ other: Rect2) -> Rect2 {
        Rect2(minX: min(minX, other.minX), minY: min(minY, other.minY), maxX: max(maxX, other.maxX), maxY: max(maxY, other.maxY))
    }

    func intersects(_ other: Rect2) -> Bool {
        minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }
}

struct ClosedBezierPath: Sendable, Equatable {
    var segments: [BezierSegment]
    /// `true` where the joint at the start of `segments[i]` is a deliberate sharp corner.
    var cornerAtStart: [Bool]

    var bounds: Rect2 {
        segments.dropFirst().reduce(segments[0].controlBounds) { $0.union($1.controlBounds) }
    }

    func mapped(_ transform: (Vec2) -> Vec2) -> ClosedBezierPath {
        ClosedBezierPath(segments: segments.map { $0.mapped(transform) }, cornerAtStart: cornerAtStart)
    }

    /// Dense sampling used for verification and diagnostics.
    func sampled(perSegment: Int = 16) -> [Vec2] {
        segments.flatMap { segment in (0..<perSegment).map { segment.point(at: Double($0) / Double(perSegment)) } }
    }
}

enum PatternOutputError: LocalizedError, Equatable {
    case invalidScale
    case noIslands
    case boundaryUnavailable(segment: Int)
    case offsetDegenerate(segment: Int)
    case doesNotFitA0
    case pdfCreationFailed
    case pdfValidationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidScale:
            "The pattern scale must be a positive, finite number of centimeters per mesh unit."
        case .noIslands:
            "There are no flattened islands to print."
        case .boundaryUnavailable(let segment):
            "Island \(segment + 1) does not have a single closed outer boundary, so no outline was produced."
        case .offsetDegenerate(let segment):
            "The seam allowance for island \(segment + 1) would fold over itself (a concave curve tighter than the allowance). No outline was produced."
        case .doesNotFitA0:
            "The pattern pieces do not fit on one A0 sheet at this scale."
        case .pdfCreationFailed:
            "The PDF could not be created."
        case .pdfValidationFailed(let reason):
            "The generated PDF failed validation: \(reason)"
        }
    }
}

enum PatternGeometry {
    static let cornerAngle = 40.0 * Double.pi / 180
    static let miterLimit = 4.0
    static let offsetTolerance = 0.02

    // MARK: Outline extraction

    /// Outer boundary of an island, counter-clockwise, as island UV points. Interior edges are traversed twice
    /// in opposite directions by consistently wound triangles, so only edges without a reverse twin remain.
    static func boundaryLoop(of island: UVIsland) throws -> [Vec2] {
        func key(_ a: Int32, _ b: Int32) -> UInt64 { UInt64(UInt32(bitPattern: a)) << 32 | UInt64(UInt32(bitPattern: b)) }

        var counts: [UInt64: Int] = [:]
        for t in 0..<(island.triangles.count / 3) {
            for k in 0..<3 {
                counts[key(island.triangles[t * 3 + k], island.triangles[t * 3 + (k + 1) % 3]), default: 0] += 1
            }
        }
        let unavailable = PatternOutputError.boundaryUnavailable(segment: island.segmentIndex)
        var next: [Int32: Int32] = [:]
        for (edge, count) in counts {
            guard count == 1 else { throw unavailable }
            let a = Int32(truncatingIfNeeded: edge >> 32), b = Int32(truncatingIfNeeded: edge & 0xFFFF_FFFF)
            if counts[key(b, a)] == nil {
                guard next.updateValue(b, forKey: a) == nil else { throw unavailable }
            }
        }
        guard let start = next.keys.min() else { throw unavailable }

        var loop: [Int32] = [start]
        var cursor = next[start]!
        while cursor != start {
            guard loop.count <= next.count, let following = next[cursor] else { throw unavailable }
            loop.append(cursor)
            cursor = following
        }
        guard loop.count == next.count else { throw unavailable }

        var points: [Vec2] = []
        for index in loop {
            let p = island.uv[Int(index)]
            if let last = points.last, vlength(p - last) < 1e-12 { continue }
            points.append(p)
        }
        if points.count > 1, vlength(points[0] - points[points.count - 1]) < 1e-12 { points.removeLast() }
        guard points.count >= 3 else { throw unavailable }

        var signedArea = 0.0
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            signedArea += a.x * b.y - b.x * a.y
        }
        guard abs(signedArea) > 1e-18 else { throw unavailable }
        return signedArea > 0 ? points : points.reversed()
    }

    // MARK: Smooth boundary

    /// Cubic Hermite boundary through every vertex. Tangents follow the local bisector so the curve is G1 on
    /// smooth stretches, while turns sharper than `cornerAngle` (seam corners, dart apexes) stay sharp.
    static func smoothClosedPath(through points: [Vec2]) -> ClosedBezierPath {
        let n = points.count
        var tangentIn = [Vec2](repeating: .zero, count: n)
        var tangentOut = [Vec2](repeating: .zero, count: n)
        var corner = [Bool](repeating: false, count: n)

        for i in 0..<n {
            let incoming = unit(points[i] - points[(i + n - 1) % n])
            let outgoing = unit(points[(i + 1) % n] - points[i])
            let turn = acos(min(1, max(-1, vdot(incoming, outgoing))))
            if turn > cornerAngle {
                corner[i] = true
                tangentIn[i] = incoming
                tangentOut[i] = outgoing
            } else {
                let bisector = unit(incoming + outgoing)
                tangentIn[i] = bisector
                tangentOut[i] = bisector
            }
        }

        var segments: [BezierSegment] = []
        for i in 0..<n {
            let j = (i + 1) % n
            let length = vlength(points[j] - points[i])
            segments.append(BezierSegment(
                p0: points[i],
                c1: points[i] + tangentOut[i] * (length / 3),
                c2: points[j] - tangentIn[j] * (length / 3),
                p3: points[j]
            ))
        }
        return ClosedBezierPath(segments: segments, cornerAtStart: corner)
    }

    // MARK: Parallel offset

    struct Offset: Sendable {
        let path: ClosedBezierPath
        /// Concave corners whose exact trim point lies beyond the adjacent curve, joined by a straight connector instead.
        let unresolvedConcaveJoins: Int
    }

    /// Parallel (offset) curve on the right-hand side of a counter-clockwise path, i.e. outward.
    ///
    /// Core Graphics has no offset-curve primitive (`CGPath.copy(strokingWithWidth:...)` returns a stroked outline,
    /// not a path), so the math is done here and only handed to `CGPath` for drawing. For a curve P(t) with unit
    /// right normal n(t), the exact offset is O(t) = P(t) + d n(t). Each cubic is approximated by the Hermite cubic
    /// that matches O and O' at both ends, split at t = 1/2 until it stays within `tolerance` of O at the samples.
    /// Convex corners get a miter (bevel beyond `miterLimit`); concave corners are trimmed to the offset-line intersection.
    static func offset(_ path: ClosedBezierPath, distance d: Double, segmentIndex: Int, tolerance: Double = offsetTolerance) throws -> Offset {
        let degenerate = PatternOutputError.offsetDegenerate(segment: segmentIndex)
        let n = path.segments.count
        var groups = try path.segments.map { try offsetCurves($0, d, tolerance, depth: 0, failure: degenerate) }

        var miters = [Vec2?](repeating: nil, count: n)
        var unresolved = 0

        for i in 0..<n where path.cornerAtStart[i] {
            let prev = (i + n - 1) % n
            let tIn = unit(path.segments[prev].derivative(at: 1))
            let tOut = unit(path.segments[i].derivative(at: 0))
            let nIn = Vec2(tIn.y, -tIn.x), nOut = Vec2(tOut.y, -tOut.x)
            let cross = tIn.x * tOut.y - tIn.y * tOut.x
            let dot = vdot(tIn, tOut)
            let corner = path.segments[i].p0
            if abs(cross) < 1e-12 && dot > 0 { continue }

            let miterPoint = corner + (nIn + nOut) * (d / (1 + dot))
            if cross > 0 {
                if dot > -0.99, 1 / sqrt((1 + dot) / 2) <= miterLimit { miters[i] = miterPoint }
            } else {
                let end = groups[prev][groups[prev].count - 1], start = groups[i][0]
                let trim = vlength(miterPoint - end.p3)
                let room = min(vlength(end.p3 - end.p0), vlength(start.p3 - start.p0)) * 0.5
                if dot > -0.99, trim <= room {
                    groups[prev][groups[prev].count - 1].c2 += miterPoint - end.p3
                    groups[prev][groups[prev].count - 1].p3 = miterPoint
                    groups[i][0].c1 += miterPoint - start.p0
                    groups[i][0].p0 = miterPoint
                } else {
                    unresolved += 1
                }
            }
        }

        var segments: [BezierSegment] = []
        var corners: [Bool] = []
        for i in 0..<n {
            let from = groups[(i + n - 1) % n].last!.p3, to = groups[i][0].p0
            var joint: [Vec2] = [from]
            if let m = miters[i] { joint.append(m) }
            joint.append(to)
            for (a, b) in zip(joint, joint.dropFirst()) where vlength(b - a) > 1e-9 {
                segments.append(.line(a, b))
                corners.append(true)
            }
            for (k, curve) in groups[i].enumerated() {
                segments.append(curve)
                corners.append(k == 0 && path.cornerAtStart[i])
            }
        }
        return Offset(path: ClosedBezierPath(segments: segments, cornerAtStart: corners), unresolvedConcaveJoins: unresolved)
    }

    /// Exact offset point and derivative of one cubic at parameter `t`.
    static func exactOffset(_ s: BezierSegment, _ t: Double, _ d: Double) -> (point: Vec2, derivative: Vec2) {
        let p1 = s.derivative(at: t), p2 = s.secondDerivative(at: t)
        let speed = vlength(p1)
        let r = Vec2(p1.y, -p1.x), rPrime = Vec2(p2.y, -p2.x)
        let normal = r / speed
        let normalPrime = rPrime / speed - r * (vdot(p1, p2) / (speed * speed * speed))
        return (s.point(at: t) + normal * d, p1 + normalPrime * d)
    }

    private static func offsetCurves(_ s: BezierSegment, _ d: Double, _ tolerance: Double, depth: Int, failure: PatternOutputError) throws -> [BezierSegment] {
        guard vlength(s.derivative(at: 0)) > 1e-12, vlength(s.derivative(at: 1)) > 1e-12 else { throw failure }
        let start = exactOffset(s, 0, d), end = exactOffset(s, 1, d)
        let fitted = BezierSegment(p0: start.point, c1: start.point + start.derivative / 3, c2: end.point - end.derivative / 3, p3: end.point)

        var worst = 0.0
        for k in 0...8 {
            let t = Double(k) / 8
            let sample = exactOffset(s, t, d)
            guard vdot(sample.derivative, s.derivative(at: t)) > 0 else { throw failure }
            worst = max(worst, vlength(fitted.point(at: t) - sample.point))
        }
        if worst <= tolerance { return [fitted] }
        guard depth < 10 else { throw failure }
        let (a, b) = s.split(at: 0.5)
        return try offsetCurves(a, d, tolerance, depth: depth + 1, failure: failure)
            + offsetCurves(b, d, tolerance, depth: depth + 1, failure: failure)
    }

    private static func unit(_ v: Vec2) -> Vec2 {
        let length = vlength(v)
        return length > 0 ? v / length : .zero
    }
}

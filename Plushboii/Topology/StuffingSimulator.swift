import Foundation
import simd

enum StuffingError: LocalizedError, Equatable {
    case invalidMesh
    case notClosed

    var errorDescription: String? {
        switch self {
        case .invalidMesh: "The mesh has no usable triangles for the stuffing simulation."
        case .notClosed: "The stuffing simulation needs a closed, consistently wound surface; every edge must be shared by exactly two triangles."
        }
    }
}

/// Quasi-static position-based inflation of the stitched pattern, to preview how the finished plush bulges.
///
/// The surface starts deflated. Each iteration projects (1) a pressure constraint that pushes the enclosed volume
/// toward `fill × target volume` (Müller et al., "Position Based Dynamics", 2007) and (2) edge constraints that keep
/// every edge between its pattern length (less a little bunching) and that length plus the fabric's stretch.
/// Pattern edge lengths therefore decide the shape: a pattern that is too small or too stiff cannot reach the
/// target volume, and one that is too big ends up baggy. Bending stiffness is not modelled, so creases are smoother
/// than a real fabric's.
enum StuffingSimulator {
    struct Options: Sendable {
        /// Enclosed volume to inflate to, as a share of the target mesh's volume.
        var fill = 1.0
        var iterations = 400
        /// Start size as a share of the target size.
        var startScale = 0.6
        var properties = FabricProperties.fleece
    }

    struct Result: Sendable {
        let positions: [Vec3]
        /// Inflated volume divided by the requested volume; below 1 means the fabric could not hold the stuffing.
        let volumeRatio: Double
        /// Edge length relative to the pattern length minus 1: positive = stretched, negative = bunched.
        let meanEdgeStrain: Double
        let maxEdgeStrain: Double
        /// RMS distance from the target mesh, as a share of its bounding-box diagonal.
        let shapeDeviation: Double
        /// True when some edge is stretched past what the fabric allows.
        let exceedsFabric: Bool
        let iterations: Int
    }

    /// `restLengths` maps `SurfaceCutter.edgeKey(a, b)` to the flat-pattern length of that edge; edges that are
    /// missing fall back to their 3D length.
    static func simulate(
        positions: [Vec3], triangles: [Int32],
        restLengths: [UInt64: Double] = [:],
        options: Options = Options()
    ) throws -> Result {
        guard positions.count >= 4, triangles.count >= 12, triangles.count % 3 == 0,
              triangles.allSatisfy({ $0 >= 0 && Int($0) < positions.count }),
              positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        else { throw StuffingError.invalidMesh }

        var edgeUse: [UInt64: Int] = [:]
        for t in stride(from: 0, to: triangles.count, by: 3) {
            for k in 0..<3 { edgeUse[SurfaceCutter.edgeKey(triangles[t + k], triangles[t + (k + 1) % 3]), default: 0] += 1 }
        }
        guard edgeUse.values.allSatisfy({ $0 == 2 }) else { throw StuffingError.notClosed }

        let targetVolume = abs(volume(positions, triangles))
        guard targetVolume > 1e-18 else { throw StuffingError.invalidMesh }
        let requested = targetVolume * max(options.fill, 0.05)

        struct Edge { var a: Int; var b: Int; var rest: Double }
        let edges: [Edge] = edgeUse.keys.sorted().map { key in
            let a = Int(key >> 32), b = Int(key & 0xFFFF_FFFF)
            let rest = restLengths[key] ?? vlength(positions[a] - positions[b])
            return Edge(a: a, b: b, rest: max(rest, 1e-12))
        }

        let stretch = max(options.properties.meanStretchFraction, FabricProperties.wovenCotton.meanStretchFraction) + AnisotropicStrain.rigidAllowance
        let bunch = options.properties.bunchAllowance
        let sign: Double = volume(positions, triangles) >= 0 ? 1 : -1

        var centroid = Vec3.zero
        for p in positions { centroid += p }
        centroid /= Double(positions.count)
        var x = positions.map { centroid + ($0 - centroid) * options.startScale }

        var used = 0
        for iteration in 0..<options.iterations {
            used = iteration + 1
            // Pressure: move each vertex along the volume gradient so the enclosed volume reaches the request.
            var gradient = [Vec3](repeating: .zero, count: x.count)
            for t in stride(from: 0, to: triangles.count, by: 3) {
                let i = Int(triangles[t]), j = Int(triangles[t + 1]), k = Int(triangles[t + 2])
                gradient[i] += vcross(x[j], x[k]) / 6
                gradient[j] += vcross(x[k], x[i]) / 6
                gradient[k] += vcross(x[i], x[j]) / 6
            }
            let current = sign * volume(x, triangles)
            let denominator = gradient.reduce(0) { $0 + vdot($1, $1) }
            if denominator > 1e-300 {
                // Under-relax so edge constraints can follow; the pressure is sustained by repeated projection.
                let lambda = 0.5 * (requested - current) / denominator
                for i in x.indices { x[i] += gradient[i] * (lambda * sign) }
            }
            // Edges: clamp each into [rest × (1 − bunch), rest × (1 + stretch)].
            for _ in 0..<2 {
                for edge in edges {
                    let delta = x[edge.b] - x[edge.a]
                    let length = vlength(delta)
                    guard length > 1e-18 else { continue }
                    let low = edge.rest * (1 - bunch), high = edge.rest * (1 + stretch)
                    let clamped = min(max(length, low), high)
                    if clamped == length { continue }
                    let correction = delta * (0.5 * (length - clamped) / length)
                    x[edge.a] += correction
                    x[edge.b] -= correction
                }
            }
            if iteration > 20, abs(current - requested) < 1e-5 * requested, maxViolation(x, edges.map { ($0.a, $0.b, $0.rest) }, low: bunch, high: stretch) < 1e-6 { break }
        }

        let finalVolume = sign * volume(x, triangles)
        var strainSum = 0.0, strainMax = -Double.infinity
        for edge in edges {
            let strain = vlength(x[edge.b] - x[edge.a]) / edge.rest - 1
            strainSum += strain
            strainMax = max(strainMax, strain)
        }
        var lower = positions[0], upper = positions[0]
        for p in positions { lower = simd_min(lower, p); upper = simd_max(upper, p) }
        let diagonal = max(vlength(upper - lower), 1e-12)
        var squared = 0.0
        for i in x.indices { squared += vdot(x[i] - positions[i], x[i] - positions[i]) }
        let stretchLimit = options.properties.meanStretchFraction + AnisotropicStrain.rigidAllowance

        return Result(
            positions: x,
            volumeRatio: finalVolume / requested,
            meanEdgeStrain: strainSum / Double(max(edges.count, 1)),
            maxEdgeStrain: strainMax.isFinite ? strainMax : 0,
            shapeDeviation: (squared / Double(x.count)).squareRoot() / diagonal,
            exceedsFabric: strainMax > stretchLimit + 1e-3,
            iterations: used
        )
    }

    /// Pattern edge lengths per original-mesh edge, averaged over every panel that contains the edge.
    /// `sourceVertices` maps each flattened mesh's vertex to the full object's vertex, when the panels came from a sub-mesh.
    static func restLengths(from groups: [(islands: [UVIsland], sourceVertices: [Int]?)]) -> [UInt64: Double] {
        var sums: [UInt64: (total: Double, count: Int)] = [:]
        for group in groups {
            for island in group.islands {
                for t in 0..<(island.triangles.count / 3) {
                    for k in 0..<3 {
                        let a = Int(island.triangles[t * 3 + k]), b = Int(island.triangles[t * 3 + (k + 1) % 3])
                        var oa = island.sourceVertex[a], ob = island.sourceVertex[b]
                        if let map = group.sourceVertices {
                            guard oa >= 0, ob >= 0, oa < map.count, ob < map.count else { continue }
                            oa = map[oa]; ob = map[ob]
                        }
                        guard oa != ob, oa >= 0, ob >= 0, oa <= Int(Int32.max), ob <= Int(Int32.max) else { continue }
                        let key = SurfaceCutter.edgeKey(Int32(oa), Int32(ob))
                        let length = vlength(island.uv[a] - island.uv[b])
                        let existing = sums[key] ?? (0, 0)
                        sums[key] = (existing.total + length, existing.count + 1)
                    }
                }
            }
        }
        return sums.mapValues { $0.total / Double($0.count) }
    }

    private static func volume(_ x: [Vec3], _ triangles: [Int32]) -> Double {
        var total = 0.0
        for t in stride(from: 0, to: triangles.count, by: 3) {
            total += vdot(x[Int(triangles[t])], vcross(x[Int(triangles[t + 1])], x[Int(triangles[t + 2])])) / 6
        }
        return total
    }

    private static func maxViolation(_ x: [Vec3], _ edges: [(Int, Int, Double)], low: Double, high: Double) -> Double {
        var worst = 0.0
        for (a, b, rest) in edges {
            let ratio = vlength(x[b] - x[a]) / rest
            worst = max(worst, 1 - low - ratio, ratio - 1 - high)
        }
        return worst
    }
}

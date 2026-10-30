import Foundation

/// Chooses stress-relief darts for rigid fabric: a slit from the point of greatest accumulated
/// angle defect (Gaussian curvature) to the nearest island edge.
enum DartPlanner {
    private static let smoothingRings = 3

    /// Returns patch-local vertices from the dart apex to a boundary vertex, or nil if the patch is flat.
    static func nextDartPath(in patch: SurfacePatch) -> [Int32]? {
        let vertexCount = patch.positions.count
        let tris = patch.triangles

        var angleSum = [Double](repeating: 0, count: vertexCount)
        var edgeCounts: [UInt64: Int] = [:]
        for t in 0..<patch.triangleCount {
            let v = [Int(tris[t * 3]), Int(tris[t * 3 + 1]), Int(tris[t * 3 + 2])]
            for k in 0..<3 {
                let o = patch.positions[v[k]]
                let e1 = patch.positions[v[(k + 1) % 3]] - o
                let e2 = patch.positions[v[(k + 2) % 3]] - o
                let cosine = vdot(e1, e2) / (vlength(e1) * vlength(e2))
                angleSum[v[k]] += acos(min(1, max(-1, cosine)))
                edgeCounts[SurfaceCutter.edgeKey(tris[t * 3 + k], tris[t * 3 + (k + 1) % 3]), default: 0] += 1
            }
        }

        var isBoundary = [Bool](repeating: false, count: vertexCount)
        var adjacency = [[Int32]](repeating: [], count: vertexCount)
        for (key, count) in edgeCounts {
            let a = Int(key >> 32), b = Int(key & 0xFFFF_FFFF)
            adjacency[a].append(Int32(b))
            adjacency[b].append(Int32(a))
            if count == 1 { isBoundary[a] = true; isBoundary[b] = true }
        }
        for v in 0..<vertexCount { adjacency[v].sort() }

        let defect = (0..<vertexCount).map { isBoundary[$0] ? 0 : 2 * Double.pi - angleSum[$0] }
        guard defect.contains(where: { $0 > 1e-9 }) else { return nil }

        var best = -1
        var bestMass = 1e-9
        var stamp = [Int32](repeating: -1, count: vertexCount)
        for apex in 0..<vertexCount where !isBoundary[apex] && defect[apex] > 0 {
            var mass = 0.0
            var frontier = [apex]
            stamp[apex] = Int32(apex)
            mass += defect[apex]
            for _ in 0..<smoothingRings {
                var next: [Int] = []
                for node in frontier {
                    for neighbour in adjacency[node] where stamp[Int(neighbour)] != Int32(apex) {
                        stamp[Int(neighbour)] = Int32(apex)
                        mass += defect[Int(neighbour)]
                        next.append(Int(neighbour))
                    }
                }
                frontier = next
            }
            if mass > bestMass { bestMass = mass; best = apex }
        }
        guard best >= 0 else { return nil }
        return pathToBoundary(from: best, patch: patch, adjacency: adjacency, isBoundary: isBoundary)
    }

    private static func pathToBoundary(
        from apex: Int,
        patch: SurfacePatch,
        adjacency: [[Int32]],
        isBoundary: [Bool]
    ) -> [Int32]? {
        var distance = [Double](repeating: .infinity, count: patch.positions.count)
        var previous = [Int32](repeating: -1, count: patch.positions.count)
        var heap = NodeHeap()
        distance[apex] = 0
        heap.push(priority: 0, node: apex)
        while let (current, node) = heap.pop() {
            if current > distance[node] { continue }
            if isBoundary[node] {
                var path = [Int32(node)]
                var cursor = node
                while cursor != apex {
                    cursor = Int(previous[cursor])
                    path.append(Int32(cursor))
                }
                return path.reversed()
            }
            for neighbour in adjacency[node] {
                let n = Int(neighbour)
                let candidate = current + vlength(patch.positions[node] - patch.positions[n])
                if candidate < distance[n] {
                    distance[n] = candidate
                    previous[n] = Int32(node)
                    heap.push(priority: candidate, node: n)
                }
            }
        }
        return nil
    }
}

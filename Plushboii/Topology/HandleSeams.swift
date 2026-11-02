import Foundation

/// Cuts that open handles (tunnels, loops) so a piece becomes a topological disc.
/// Uses a tree-cotree decomposition: the cut graph is the minimal tree-path network joining the
/// leftover edges, which leaves exactly 2g + b - 1 independent loops for genus g and b boundary loops.
enum HandleSeams {
    /// Genus of a connected manifold piece, from V - E + F and its boundary-loop count.
    static func genus(triangles: [Int32]) -> Int {
        guard triangles.count >= 3 else { return 0 }
        var vertices = Set<Int32>(), edges = Set<UInt64>()
        for t in stride(from: 0, to: triangles.count, by: 3) {
            for k in 0..<3 {
                let a = triangles[t + k], b = triangles[t + (k + 1) % 3]
                vertices.insert(a)
                edges.insert(SurfaceCutter.edgeKey(a, b))
            }
        }
        let euler = vertices.count - edges.count + triangles.count / 3
        let boundary = OpenPieceSeams.boundaryLoops(triangles: triangles).count
        return max(0, (2 - euler - boundary) / 2)
    }

    /// One 2-vertex path per cut edge, or an empty array for a piece with no handles.
    static func seams(positions: [Vec3], triangles: [Int32]) -> [[Int]] {
        guard genus(triangles: triangles) > 0 else { return [] }
        let faceCount = triangles.count / 3

        var neighbours = [Int: [Int]]()
        var facesOfEdge = [UInt64: [Int]]()
        var edgeEnds = [UInt64: (Int, Int)]()
        for f in 0..<faceCount {
            for k in 0..<3 {
                let a = Int(triangles[3 * f + k]), b = Int(triangles[3 * f + (k + 1) % 3])
                let key = SurfaceCutter.edgeKey(Int32(a), Int32(b))
                if facesOfEdge[key] == nil {
                    edgeEnds[key] = (a, b)
                    neighbours[a, default: []].append(b)
                    neighbours[b, default: []].append(a)
                }
                facesOfEdge[key, default: []].append(f)
            }
        }
        guard let root = neighbours.keys.min() else { return [] }

        var parent = [Int: Int]()
        var queue = [root], head = 0
        var treeEdges = Set<UInt64>()
        parent[root] = -1
        while head < queue.count {
            let u = queue[head]; head += 1
            for n in neighbours[u] ?? [] where parent[n] == nil {
                parent[n] = u
                treeEdges.insert(SurfaceCutter.edgeKey(Int32(u), Int32(n)))
                queue.append(n)
            }
        }

        // Cotree: spanning tree of the dual graph over the non-tree edges; the outside of an open piece is one extra node.
        var dual = Array(0...faceCount)
        func find(_ i: Int) -> Int {
            var i = i
            while dual[i] != i { dual[i] = dual[dual[i]]; i = dual[i] }
            return i
        }
        func length(_ key: UInt64) -> Double {
            guard let (a, b) = edgeEnds[key] else { return 0 }
            return vlength(positions[a] - positions[b])
        }
        let candidates = facesOfEdge.keys.filter { !treeEdges.contains($0) }.sorted {
            let l = length($0), r = length($1)
            return l == r ? $0 < $1 : l > r
        }
        var leftover: [UInt64] = []
        for key in candidates {
            let faces = facesOfEdge[key] ?? []
            let a = faces[0], b = faces.count > 1 ? faces[1] : faceCount
            let ra = find(a), rb = find(b)
            if ra == rb { leftover.append(key) } else { dual[ra] = rb }
        }

        var core = Set(leftover)
        for key in leftover {
            guard let (a, b) = edgeEnds[key] else { continue }
            for start in [a, b] {
                var v = start
                while let p = parent[v], p != -1 {
                    core.insert(SurfaceCutter.edgeKey(Int32(v), Int32(p)))
                    v = p
                }
            }
        }

        // Dangling branches are not part of the cut graph.
        var degree = [Int: Int]()
        for key in core { if let (a, b) = edgeEnds[key] { degree[a, default: 0] += 1; degree[b, default: 0] += 1 } }
        var changed = true
        while changed {
            changed = false
            for key in core {
                guard let (a, b) = edgeEnds[key], degree[a] == 1 || degree[b] == 1 else { continue }
                core.remove(key)
                degree[a, default: 0] -= 1; degree[b, default: 0] -= 1
                changed = true
            }
        }
        return core.sorted().compactMap { key in edgeEnds[key].map { [$0.0, $0.1] } }
    }
}

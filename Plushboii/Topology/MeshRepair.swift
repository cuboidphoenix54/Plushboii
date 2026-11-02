import Foundation

/// Resolves non-manifold edges (more than two faces on one edge) by splitting vertices so that each
/// edge-connected fan of faces gets its own copy. The new open boundaries become forced seams, the same
/// treatment Plushify applies to non-manifold edges.
enum MeshRepair {
    struct Result: Sendable {
        let positions: [Vec3]
        let triangles: [Int32]
        /// For each output vertex, the index of the original vertex it was copied from.
        let sourceVertex: [Int]
        let nonManifoldEdges: Int
    }

    private struct EdgeKey: Hashable {
        let a: Int32, b: Int32
        init(_ x: Int32, _ y: Int32) { a = min(x, y); b = max(x, y) }
    }

    static func resolveNonManifoldEdges(positions: [Vec3], triangles: [Int32]) -> Result {
        let faceCount = triangles.count / 3
        var edgeFaces: [EdgeKey: [Int]] = [:]
        for f in 0..<faceCount {
            for k in 0..<3 {
                edgeFaces[EdgeKey(triangles[3 * f + k], triangles[3 * f + (k + 1) % 3]), default: []].append(f)
            }
        }
        let bad = edgeFaces.filter { $0.value.count > 2 }
        guard !bad.isEmpty else {
            return Result(positions: positions, triangles: triangles, sourceVertex: Array(0..<positions.count), nonManifoldEdges: 0)
        }

        // Faces may only be joined across edges shared by exactly two faces.
        var vertexFaces: [Int32: [Int]] = [:]
        for f in 0..<faceCount { for k in 0..<3 { vertexFaces[triangles[3 * f + k], default: []].append(f) } }

        var outPositions = positions
        var source = Array(0..<positions.count)
        var out = triangles
        for (vertex, faces) in vertexFaces {
            let touchesBad = faces.contains { f in
                (0..<3).contains { k in
                    edgeFaces[EdgeKey(triangles[3 * f + k], triangles[3 * f + (k + 1) % 3])]!.count > 2
                }
            }
            guard touchesBad else { continue }
            let local = Set(faces)
            var group: [Int: Int] = [:]
            var groups = 0
            for seed in faces where group[seed] == nil {
                var stack = [seed]
                group[seed] = groups
                while let f = stack.popLast() {
                    for k in 0..<3 {
                        let a = triangles[3 * f + k], b = triangles[3 * f + (k + 1) % 3]
                        guard a == vertex || b == vertex else { continue }
                        let neighbors = edgeFaces[EdgeKey(a, b)]!
                        guard neighbors.count == 2 else { continue }
                        for n in neighbors where n != f && local.contains(n) && group[n] == nil {
                            group[n] = groups
                            stack.append(n)
                        }
                    }
                }
                groups += 1
            }
            guard groups > 1 else { continue }
            var copies = [Int32](repeating: vertex, count: groups)
            for g in 1..<groups {
                copies[g] = Int32(outPositions.count)
                outPositions.append(positions[Int(vertex)])
                source.append(Int(vertex))
            }
            for f in faces {
                for k in 0..<3 where triangles[3 * f + k] == vertex { out[3 * f + k] = copies[group[f]!] }
            }
        }
        return Result(positions: outPositions, triangles: out, sourceVertex: source, nonManifoldEdges: bad.count)
    }
}

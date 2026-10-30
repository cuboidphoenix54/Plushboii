import Foundation

/// A triangle patch whose vertices have been cut apart along seams.
struct SurfacePatch: Sendable {
    let positions: [Vec3]
    /// Flat triangle list with patch-local vertex indices.
    let triangles: [Int32]
    /// Vertex index in the original mesh for each patch vertex.
    let origin: [Int]

    var triangleCount: Int { triangles.count / 3 }

    static func whole(positions: [Vec3], triangles: [Int32]) -> SurfacePatch {
        SurfacePatch(positions: positions, triangles: triangles, origin: Array(0..<positions.count))
    }
}

enum SurfaceCutter {
    static func edgeKey(_ a: Int32, _ b: Int32) -> UInt64 {
        let lo = min(a, b), hi = max(a, b)
        return UInt64(UInt32(lo)) << 32 | UInt64(UInt32(hi))
    }

    /// Splits `patch` into connected components, treating every edge in `cuts` as a barrier.
    /// Vertices touched by a cut are duplicated wherever the surrounding triangle fan is severed.
    static func components(of patch: SurfacePatch, cutting cuts: Set<UInt64>) throws -> [SurfacePatch] {
        let triangleCount = patch.triangleCount
        let tris = patch.triangles

        var entries: [(key: UInt64, tri: Int32)] = []
        entries.reserveCapacity(triangleCount * 3)
        for t in 0..<triangleCount {
            for k in 0..<3 {
                entries.append((edgeKey(tris[t * 3 + k], tris[t * 3 + (k + 1) % 3]), Int32(t)))
            }
        }
        entries.sort { $0.key != $1.key ? $0.key < $1.key : $0.tri < $1.tri }

        var triangleSets = UnionFind(count: triangleCount)
        var cornerSets = UnionFind(count: triangleCount * 3)
        var matchedCuts = Set<UInt64>()

        func corner(_ t: Int, _ vertex: Int32) -> Int {
            for k in 0..<3 where tris[t * 3 + k] == vertex { return t * 3 + k }
            return t * 3
        }

        var i = 0
        while i < entries.count {
            var j = i + 1
            while j < entries.count && entries[j].key == entries[i].key { j += 1 }
            let key = entries[i].key
            if j - i > 2 { throw FlatteningError.nonManifoldEdge }
            if cuts.contains(key) {
                matchedCuts.insert(key)
            } else if j - i == 2 {
                let t1 = Int(entries[i].tri), t2 = Int(entries[i + 1].tri)
                triangleSets.union(t1, t2)
                for vertex in [Int32(truncatingIfNeeded: key >> 32), Int32(truncatingIfNeeded: key & 0xFFFF_FFFF)] {
                    cornerSets.union(corner(t1, vertex), corner(t2, vertex))
                }
            }
            i = j
        }

        if let missing = cuts.subtracting(matchedCuts).min() {
            throw FlatteningError.seamEdgeNotOnMesh(Int(missing >> 32), Int(missing & 0xFFFF_FFFF))
        }

        var segmentOfRoot = [Int32](repeating: -1, count: triangleCount)
        var segmentTriangles: [[Int]] = []
        for t in 0..<triangleCount {
            let root = triangleSets.find(t)
            if segmentOfRoot[root] < 0 {
                segmentOfRoot[root] = Int32(segmentTriangles.count)
                segmentTriangles.append([])
            }
            segmentTriangles[Int(segmentOfRoot[root])].append(t)
        }

        var localOfCornerRoot = [Int32](repeating: -1, count: triangleCount * 3)
        return segmentTriangles.map { members in
            var positions: [Vec3] = []
            var origin: [Int] = []
            var local: [Int32] = []
            local.reserveCapacity(members.count * 3)
            for t in members {
                for k in 0..<3 {
                    let root = cornerSets.find(t * 3 + k)
                    if localOfCornerRoot[root] < 0 {
                        localOfCornerRoot[root] = Int32(positions.count)
                        let vertex = Int(tris[t * 3 + k])
                        positions.append(patch.positions[vertex])
                        origin.append(patch.origin[vertex])
                    }
                    local.append(localOfCornerRoot[root])
                }
            }
            return SurfacePatch(positions: positions, triangles: local, origin: origin)
        }
    }

    /// Verifies the patch is a topological disc and returns its single boundary loop.
    static func boundaryLoop(of patch: SurfacePatch, segment: Int) throws -> [Int32] {
        let tris = patch.triangles
        var keys: [UInt64] = []
        keys.reserveCapacity(tris.count)
        for t in 0..<patch.triangleCount {
            for k in 0..<3 {
                keys.append(edgeKey(tris[t * 3 + k], tris[t * 3 + (k + 1) % 3]))
            }
        }
        keys.sort()

        var edgeCount = 0
        var boundaryNeighbours: [Int32: [Int32]] = [:]
        var i = 0
        while i < keys.count {
            var j = i + 1
            while j < keys.count && keys[j] == keys[i] { j += 1 }
            edgeCount += 1
            if j - i == 1 {
                let a = Int32(truncatingIfNeeded: keys[i] >> 32)
                let b = Int32(truncatingIfNeeded: keys[i] & 0xFFFF_FFFF)
                boundaryNeighbours[a, default: []].append(b)
                boundaryNeighbours[b, default: []].append(a)
            }
            i = j
        }

        let euler = patch.positions.count - edgeCount + patch.triangleCount
        guard boundaryNeighbours.values.allSatisfy({ $0.count == 2 }) else {
            throw FlatteningError.notDisc(segment: segment, euler: euler, boundaryLoops: -1)
        }

        var visited = Set<Int32>()
        var loops: [[Int32]] = []
        for start in boundaryNeighbours.keys.sorted() where !visited.contains(start) {
            var loop: [Int32] = [start]
            visited.insert(start)
            var previous = start
            var current = boundaryNeighbours[start]!.min()!
            while current != start {
                loop.append(current)
                visited.insert(current)
                let next = boundaryNeighbours[current]!.first { $0 != previous } ?? previous
                previous = current
                current = next
            }
            loops.append(loop)
        }

        guard euler == 1, loops.count == 1 else {
            throw FlatteningError.notDisc(segment: segment, euler: euler, boundaryLoops: loops.count)
        }
        return loops[0]
    }
}

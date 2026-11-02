import Foundation

enum PanelSplitPlanner {
    private struct Edge {
        let destination: Int
        let length: Double
    }

    private struct QueueEntry {
        let distance: Double
        let vertex: Int
    }

    private struct Candidate {
        let path: [Int32]
        let imbalance: Double
        let length: Double
    }

    static func candidatePaths(in patch: SurfacePatch) throws -> [[Int32]] {
        let boundary = try SurfaceCutter.boundaryLoop(of: patch, segment: 0).map(Int.init)
        guard boundary.count >= 6 else { return [] }

        var edgeCounts: [UInt64: Int] = [:]
        var adjacency = Array(repeating: [Edge](), count: patch.positions.count)
        for triangle in 0..<patch.triangleCount {
            for corner in 0..<3 {
                let a = Int(patch.triangles[triangle * 3 + corner])
                let b = Int(patch.triangles[triangle * 3 + (corner + 1) % 3])
                edgeCounts[SurfaceCutter.edgeKey(Int32(a), Int32(b)), default: 0] += 1
            }
        }
        for (key, count) in edgeCounts where count == 2 {
            let a = Int(key >> 32)
            let b = Int(key & 0xFFFF_FFFF)
            let length = vlength(patch.positions[a] - patch.positions[b])
            guard length.isFinite, length > 0 else { continue }
            adjacency[a].append(Edge(destination: b, length: length))
            adjacency[b].append(Edge(destination: a, length: length))
        }
        for vertex in adjacency.indices {
            adjacency[vertex].sort { $0.destination < $1.destination }
        }

        let boundaryVertices = Set(boundary)
        var candidates: [Candidate] = []
        var seen = Set<[Int32]>()
        let sampleCount = min(8, max(2, boundary.count / 2))
        for offset in 0..<sampleCount {
            let startIndex = offset * boundary.count / sampleCount
            let endIndex = (startIndex + boundary.count / 2) % boundary.count
            let start = boundary[startIndex]
            let end = boundary[endIndex]
            guard start != end, let path = shortestInteriorPath(
                from: start,
                to: end,
                adjacency: adjacency,
                boundaryVertices: boundaryVertices,
                vertexCount: patch.positions.count
            ) else {
                continue
            }
            let key = canonical(path)
            if seen.insert(key).inserted {
                let cuts = Set(zip(path, path.dropFirst()).map { SurfaceCutter.edgeKey($0, $1) })
                let pieces = try SurfaceCutter.components(of: patch, cutting: cuts)
                if pieces.count == 2, pieces.allSatisfy({ $0.triangleCount >= 4 }) {
                    let total = pieces[0].triangleCount + pieces[1].triangleCount
                    let imbalance = Double(abs(pieces[0].triangleCount - pieces[1].triangleCount)) / Double(total)
                    let length = zip(path, path.dropFirst()).reduce(0.0) { partial, edge in
                        partial + vlength(patch.positions[Int(edge.0)] - patch.positions[Int(edge.1)])
                    }
                    candidates.append(Candidate(path: path, imbalance: imbalance, length: length))
                }
            }
        }
        return candidates
            .sorted {
                if $0.imbalance != $1.imbalance { return $0.imbalance < $1.imbalance }
                return $0.length < $1.length
            }
            .prefix(4)
            .map(\.path)
    }

    private static func shortestInteriorPath(
        from start: Int,
        to end: Int,
        adjacency: [[Edge]],
        boundaryVertices: Set<Int>,
        vertexCount: Int
    ) -> [Int32]? {
        var distances = [Double](repeating: .infinity, count: vertexCount)
        var previous = [Int](repeating: -1, count: vertexCount)
        var queue: [QueueEntry] = []
        distances[start] = 0
        push(QueueEntry(distance: 0, vertex: start), into: &queue)

        while let current = pop(from: &queue) {
            if current.distance != distances[current.vertex] { continue }
            if current.vertex == end { break }
            for edge in adjacency[current.vertex] {
                guard edge.destination != start,
                      edge.destination == end || !boundaryVertices.contains(edge.destination) else {
                    continue
                }
                let nextDistance = current.distance + edge.length
                if nextDistance < distances[edge.destination] {
                    distances[edge.destination] = nextDistance
                    previous[edge.destination] = current.vertex
                    push(QueueEntry(distance: nextDistance, vertex: edge.destination), into: &queue)
                }
            }
        }

        guard distances[end].isFinite else { return nil }
        var reversePath = [end]
        var cursor = end
        while cursor != start {
            cursor = previous[cursor]
            guard cursor >= 0 else { return nil }
            reversePath.append(cursor)
            guard reversePath.count <= vertexCount else { return nil }
        }
        return reversePath.reversed().map(Int32.init)
    }

    private static func canonical(_ path: [Int32]) -> [Int32] {
        let reversed = path.reversed()
        return path.lexicographicallyPrecedes(reversed) ? path : Array(reversed)
    }

    private static func push(_ entry: QueueEntry, into heap: inout [QueueEntry]) {
        heap.append(entry)
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[child].distance < heap[parent].distance else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private static func pop(from heap: inout [QueueEntry]) -> QueueEntry? {
        guard !heap.isEmpty else { return nil }
        if heap.count == 1 { return heap.removeLast() }
        let first = heap[0]
        heap[0] = heap.removeLast()
        var parent = 0
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            guard left < heap.count else { break }
            let child = right < heap.count && heap[right].distance < heap[left].distance ? right : left
            guard heap[child].distance < heap[parent].distance else { break }
            heap.swapAt(child, parent)
            parent = child
        }
        return first
    }
}

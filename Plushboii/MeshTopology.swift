import Foundation
import simd

struct RawControlPoint: Sendable {
    let index: Int
    let x: Double
    let y: Double
    let z: Double
}

struct LoadedMesh: Sendable {
    let topology: MeshTopology
    let seams: [SeamPath]
}

/// Immutable, validated mesh with a vertex adjacency graph. Positions are centred on the origin.
struct MeshTopology: Sendable, Equatable {
    let id = UUID()
    let positions: [SIMD3<Double>]
    let triangles: [Int32]
    let normals: [SIMD3<Float>]
    let radius: Double
    private let adjacencyOffsets: [Int]
    private let adjacencyList: [Int32]

    static func == (lhs: MeshTopology, rhs: MeshTopology) -> Bool {
        lhs.id == rhs.id
    }

    init?(positions rawPositions: [SIMD3<Double>], triangles flat: [Int32]) {
        let count = rawPositions.count
        guard
            count > 0,
            flat.count >= 3,
            flat.count % 3 == 0,
            rawPositions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
            flat.allSatisfy({ $0 >= 0 && Int($0) < count })
        else {
            return nil
        }

        let centre = rawPositions.reduce(SIMD3<Double>.zero, +) / Double(count)
        let centred = rawPositions.map { $0 - centre }
        let radius = centred.map { simd_length($0) }.max() ?? 0
        guard radius.isFinite, radius > 0 else { return nil }

        var accumulatedNormals = [SIMD3<Double>](repeating: .zero, count: count)
        var offsets = [Int](repeating: 0, count: count + 1)
        for t in stride(from: 0, to: flat.count, by: 3) {
            let a = Int(flat[t]), b = Int(flat[t + 1]), c = Int(flat[t + 2])
            let faceNormal = simd_cross(centred[b] - centred[a], centred[c] - centred[a])
            accumulatedNormals[a] += faceNormal
            accumulatedNormals[b] += faceNormal
            accumulatedNormals[c] += faceNormal
            for vertex in [a, b, c] {
                offsets[vertex + 1] += 2
            }
        }
        for i in 0..<count {
            offsets[i + 1] += offsets[i]
        }

        var cursor = offsets
        var list = [Int32](repeating: 0, count: flat.count * 2)
        for t in stride(from: 0, to: flat.count, by: 3) {
            let corners = [Int(flat[t]), Int(flat[t + 1]), Int(flat[t + 2])]
            for corner in 0..<3 {
                let u = corners[corner]
                for neighbour in [corners[(corner + 1) % 3], corners[(corner + 2) % 3]] {
                    list[cursor[u]] = Int32(neighbour)
                    cursor[u] += 1
                }
            }
        }

        self.positions = centred
        self.triangles = flat
        self.radius = radius
        self.adjacencyOffsets = offsets
        self.adjacencyList = list
        self.normals = accumulatedNormals.map { normal in
            let length = simd_length(normal)
            return length > 0 ? SIMD3<Float>(normal / length) : SIMD3<Float>(0, 0, 1)
        }
    }

    func isAdjacent(_ a: Int, _ b: Int) -> Bool {
        guard positions.indices.contains(a), positions.indices.contains(b) else { return false }
        for k in adjacencyOffsets[a]..<adjacencyOffsets[a + 1] where Int(adjacencyList[k]) == b {
            return true
        }
        return false
    }

    /// Dijkstra over mesh edges, so the returned path is always contiguous along real edges.
    func shortestPath(from start: Int, to goal: Int) -> [Int]? {
        guard positions.indices.contains(start), positions.indices.contains(goal) else { return nil }
        if start == goal { return [start] }

        var distance = [Double](repeating: .infinity, count: positions.count)
        var previous = [Int32](repeating: -1, count: positions.count)
        var heap = MinHeap()
        distance[start] = 0
        heap.push(priority: 0, node: start)

        while let (current, node) = heap.pop() {
            if current > distance[node] { continue }
            if node == goal { break }
            for k in adjacencyOffsets[node]..<adjacencyOffsets[node + 1] {
                let neighbour = Int(adjacencyList[k])
                let candidate = current + simd_distance(positions[node], positions[neighbour])
                if candidate < distance[neighbour] {
                    distance[neighbour] = candidate
                    previous[neighbour] = Int32(node)
                    heap.push(priority: candidate, node: neighbour)
                }
            }
        }

        guard distance[goal].isFinite else { return nil }
        var path = [goal]
        var node = goal
        while node != start {
            let parent = Int(previous[node])
            guard parent >= 0 else { return nil }
            path.append(parent)
            node = parent
        }
        return path.reversed()
    }

    /// Validates stored geometry and seams; anything inconsistent is rejected rather than repaired.
    static func load(points: [RawControlPoint], vertexData: Data = Data(), faceData: Data, seamData: Data) -> LoadedMesh? {
        let positions: [SIMD3<Double>]
        if vertexData.isEmpty {
            let sorted = points.sorted { $0.index < $1.index }
            guard sorted.indices.allSatisfy({ sorted[$0].index == $0 }) else { return nil }
            positions = sorted.map { SIMD3<Double>($0.x, $0.y, $0.z) }
        } else {
            let stride = 3 * MemoryLayout<Double>.size
            guard vertexData.count % stride == 0 else { return nil }
            var coordinates = [Double](repeating: 0, count: vertexData.count / MemoryLayout<Double>.size)
            coordinates.withUnsafeMutableBytes { _ = vertexData.copyBytes(to: $0) }
            positions = (0..<(coordinates.count / 3)).map {
                SIMD3<Double>(coordinates[$0 * 3], coordinates[$0 * 3 + 1], coordinates[$0 * 3 + 2])
            }
        }
        guard
            let faces = try? JSONDecoder().decode([[Int]].self, from: faceData),
            faces.allSatisfy({ $0.count == 3 }),
            faces.allSatisfy({ $0.allSatisfy { $0 >= 0 && $0 < Int(Int32.max) } })
        else {
            return nil
        }
        guard let topology = MeshTopology(positions: positions, triangles: faces.flatMap { $0.map(Int32.init) }) else {
            return nil
        }

        var seams: [SeamPath] = []
        if !seamData.isEmpty, let stored = try? JSONDecoder().decode([[Int]].self, from: seamData) {
            for vertices in stored where vertices.count >= 1 {
                let inRange = vertices.allSatisfy { positions.indices.contains($0) }
                let contiguous = zip(vertices, vertices.dropFirst()).allSatisfy { topology.isAdjacent($0, $1) }
                if inRange && contiguous {
                    seams.append(SeamPath(
                        vertices: vertices,
                        anchorEnds: Array(1...vertices.count),
                        isClosed: vertices.count > 3 && vertices.first == vertices.last
                    ))
                }
            }
        }
        return LoadedMesh(topology: topology, seams: seams)
    }
}

private struct MinHeap {
    private var items: [(priority: Double, node: Int)] = []

    mutating func push(priority: Double, node: Int) {
        items.append((priority, node))
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            if items[parent].priority <= items[child].priority { break }
            items.swapAt(parent, child)
            child = parent
        }
    }

    mutating func pop() -> (Double, Int)? {
        guard let first = items.first else { return nil }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var parent = 0
            while true {
                let left = parent * 2 + 1
                let right = left + 1
                var smallest = parent
                if left < items.count, items[left].priority < items[smallest].priority { smallest = left }
                if right < items.count, items[right].priority < items[smallest].priority { smallest = right }
                if smallest == parent { break }
                items.swapAt(parent, smallest)
                parent = smallest
            }
        }
        return (first.priority, first.node)
    }
}

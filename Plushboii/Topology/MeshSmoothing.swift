import Foundation

/// Removes surface lumpiness before patterning. Taubin smoothing alternates a shrinking and an inflating
/// Laplacian step, so overall volume and the overall silhouette (head, limbs) are kept.
enum MeshSmoothing {
    static let shrinkFactor = 0.5
    static let inflateFactor = -0.53
    static let defaultIterations = 10

    /// Only positions change; triangle and vertex indices are untouched.
    static func taubin(positions: [Vec3], triangles: [Int32], iterations: Int = defaultIterations) -> [Vec3] {
        guard iterations > 0, positions.count >= 3, triangles.count >= 3 else { return positions }
        var neighbors = [Set<Int>](repeating: [], count: positions.count)
        for t in stride(from: 0, to: triangles.count - 2, by: 3) {
            let a = Int(triangles[t]), b = Int(triangles[t + 1]), c = Int(triangles[t + 2])
            guard a >= 0, b >= 0, c >= 0, a < positions.count, b < positions.count, c < positions.count else { return positions }
            neighbors[a].formUnion([b, c]); neighbors[b].formUnion([a, c]); neighbors[c].formUnion([a, b])
        }
        let lists = neighbors.map { Array($0).sorted() }
        // Vertices on open boundaries stay put so cut edges still match their neighbours.
        let fixed = Set(OpenPieceSeams.boundaryLoops(triangles: triangles).flatMap { $0 })

        func step(_ input: [Vec3], factor: Double) -> [Vec3] {
            var output = input
            for index in input.indices where !lists[index].isEmpty && !fixed.contains(index) {
                var sum = Vec3.zero
                for neighbor in lists[index] { sum = sum + input[neighbor] }
                let average = sum / Double(lists[index].count)
                output[index] = input[index] + (average - input[index]) * factor
            }
            return output
        }

        var current = positions
        for _ in 0..<iterations {
            current = step(current, factor: shrinkFactor)
            current = step(current, factor: inflateFactor)
        }
        return current.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite } ? current : positions
    }
}

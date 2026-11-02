import Foundation

/// Seams for pieces that already have open boundaries (e.g. a torso left after neck and limb cuts).
/// A piece with k > 1 boundary loops is not a disc; joining the loops with k - 1 shortest cuts makes it one.
enum OpenPieceSeams {
    private struct HeapItem { let distance: Double; let vertex: Int }

    static func boundaryLoops(triangles: [Int32]) -> [[Int]] {
        var edgeCounts: [UInt64: Int] = [:]
        for t in stride(from: 0, to: triangles.count, by: 3) {
            for k in 0..<3 {
                edgeCounts[SurfaceCutter.edgeKey(triangles[t + k], triangles[t + (k + 1) % 3]), default: 0] += 1
            }
        }
        var next: [Int: [Int]] = [:]
        for (key, count) in edgeCounts where count == 1 {
            let a = Int(Int32(truncatingIfNeeded: key >> 32)), b = Int(Int32(truncatingIfNeeded: key & 0xFFFF_FFFF))
            next[a, default: []].append(b)
            next[b, default: []].append(a)
        }
        var visited = Set<Int>()
        var loops: [[Int]] = []
        for start in next.keys.sorted() where !visited.contains(start) {
            var loop = [start]
            visited.insert(start)
            var previous = -1, current = start
            while let step = next[current]?.sorted().first(where: { $0 != previous && !visited.contains($0) }) {
                loop.append(step)
                visited.insert(step)
                previous = current
                current = step
            }
            loops.append(loop)
        }
        return loops
    }

    /// Shortest paths between boundary loops through interior vertices, joined as a minimum spanning tree.
    static func joiningSeams(positions: [Vec3], triangles: [Int32]) -> [[Int]] {
        let loops = boundaryLoops(triangles: triangles)
        guard loops.count > 1 else { return [] }
        var loopOf: [Int: Int] = [:]
        for (index, loop) in loops.enumerated() { for v in loop { loopOf[v] = index } }

        var neighbours = [[Int]](repeating: [], count: positions.count)
        var seen = Set<UInt64>()
        for t in stride(from: 0, to: triangles.count, by: 3) {
            for k in 0..<3 {
                let a = triangles[t + k], b = triangles[t + (k + 1) % 3]
                if seen.insert(SurfaceCutter.edgeKey(a, b)).inserted {
                    neighbours[Int(a)].append(Int(b))
                    neighbours[Int(b)].append(Int(a))
                }
            }
        }

        // Cheapest path from every loop to every other loop.
        var candidates: [(from: Int, to: Int, length: Double, path: [Int])] = []
        for source in loops.indices {
            var distance = [Double](repeating: .infinity, count: positions.count)
            var previous = [Int](repeating: -1, count: positions.count)
            var open = Set<Int>(loops[source])
            for v in loops[source] { distance[v] = 0 }
            var best: [Int: Int] = [:]
            while let u = open.min(by: { distance[$0] < distance[$1] }) {
                open.remove(u)
                if let l = loopOf[u], l != source {
                    if best[l] == nil { best[l] = u }
                    continue
                }
                for n in neighbours[u] {
                    if loopOf[n] == source { continue }
                    let d = distance[u] + vlength(positions[n] - positions[u])
                    if d < distance[n] { distance[n] = d; previous[n] = u; open.insert(n) }
                }
            }
            for (target, end) in best where target > source {
                var path = [end]
                while previous[path[path.count - 1]] != -1 { path.append(previous[path[path.count - 1]]) }
                candidates.append((source, target, distance[end], path.reversed()))
            }
        }

        var parent = Array(loops.indices)
        func root(_ i: Int) -> Int { parent[i] == i ? i : { parent[i] = root(parent[i]); return parent[i] }() }
        var seams: [[Int]] = []
        for c in candidates.sorted(by: { $0.length < $1.length }) where root(c.from) != root(c.to) {
            parent[root(c.from)] = root(c.to)
            seams.append(c.path)
        }
        return seams
    }

    struct Solution: Sendable {
        let seams: [[Int]]
        let result: FlatteningResult
    }

    /// Flattens a piece that has open boundaries: joins its loops into a disc, then adds the chord cut
    /// (boundary to boundary through the interior) that most reduces distortion until every panel verifies.
    static func solve(
        positions: [Vec3],
        triangles: [Int32],
        fabric: FabricProfile,
        maximumChords: Int = 10,
        visibility: SeamVisibility = .none
    ) throws -> Solution? {
        let handleSeams = HandleSeams.seams(positions: positions, triangles: triangles)
        guard !boundaryLoops(triangles: triangles).isEmpty || !handleSeams.isEmpty else { return nil }
        var seams = handleSeams.isEmpty ? joiningSeams(positions: positions, triangles: triangles) : handleSeams
        var neighbours = [[Int]](repeating: [], count: positions.count)
        var seen = Set<UInt64>()
        for t in stride(from: 0, to: triangles.count, by: 3) {
            for k in 0..<3 {
                let a = triangles[t + k], b = triangles[t + (k + 1) % 3]
                if seen.insert(SurfaceCutter.edgeKey(a, b)).inserted {
                    neighbours[Int(a)].append(Int(b))
                    neighbours[Int(b)].append(Int(a))
                }
            }
        }
        let loopVertices = Set(boundaryLoops(triangles: triangles).flatMap { $0 })

        func worst(_ candidate: [[Int]]) -> Double {
            guard let loose = try? TopologyEngine.flatten(positions: positions, triangles: triangles, seams: candidate, fabric: fabric, tolerance: 100, refine: false) else { return .infinity }
            let distortion = loose.islands.map { $0.report.areaDelta + ($0.report.flippedTriangles > 0 ? 1 : 0) }.max() ?? .infinity
            let uniformity = SeamRules.uniformity(PieceCongruence.groups(for: loose), pieceCount: loose.islands.count)
            let sewing = (loose.islands.count > 1 ? 0.25 * (1 - uniformity) : 0)
                + SeamVisibility.weightInSeamScore * visibility.penalty(of: candidate, positions: positions)
            return distortion + 0.5 * min(stitchMismatch(islands: loose.islands, seams: candidate), 2) + sewing
        }

        var bestPetals: [[Int]] = []
        var bestStart = worst(seams)
        let loops = boundaryLoops(triangles: triangles)
        if let loop = loops.max(by: { $0.count < $1.count }) {
            for petals in 3...8 {
                guard let candidate = petalSeams(positions: positions, neighbours: neighbours, loop: loop, boundary: loopVertices, petals: petals) else { continue }
                let value = worst(seams + candidate)
                if value < bestStart { bestStart = value; bestPetals = candidate }
            }
        }
        seams += bestPetals

        var lastError: Error?
        for round in 0...maximumChords {
            do {
                var result = try TopologyEngine.flatten(positions: positions, triangles: triangles, seams: seams, fabric: fabric)
                var changed = true
                while changed, seams.count > 1 {
                    changed = false
                    for index in seams.indices.reversed() {
                        var trial = seams
                        trial.remove(at: index)
                        guard let simpler = try? TopologyEngine.flatten(positions: positions, triangles: triangles, seams: trial, fabric: fabric),
                              simpler.islands.count <= result.islands.count,
                              stitchMismatch(islands: simpler.islands, seams: trial) <= stitchMismatch(islands: result.islands, seams: seams) + 0.05,
                              meanStretch(simpler.islands, positions: positions) <= meanStretch(result.islands, positions: positions) + 0.02
                        else { continue }
                        seams = trial
                        result = simpler
                        changed = true
                        break
                    }
                }
                // Add a chord when it clearly lowers the stretch without worsening the stitch lengths.
                var stretch = meanStretch(result.islands, positions: positions)
                if stretch > 0.2 {
                    let cutVertices = loopVertices.union(seams.flatMap { $0 })
                    let samples = farthestSamples(of: cutVertices.sorted(), positions: positions, count: 8)
                    var improved: (stretch: Double, seams: [[Int]], result: FlatteningResult)?
                    for chord in chords(among: samples, cutVertices: cutVertices, positions: positions, neighbours: neighbours) {
                        let trial = seams + [chord]
                        guard let candidate = try? TopologyEngine.flatten(positions: positions, triangles: triangles, seams: trial, fabric: fabric),
                              stitchMismatch(islands: candidate.islands, seams: trial) <= stitchMismatch(islands: result.islands, seams: seams) + 0.1
                        else { continue }
                        let value = meanStretch(candidate.islands, positions: positions)
                        if value < stretch * 0.7, value < (improved?.stretch ?? .infinity) { improved = (value, trial, candidate) }
                    }
                    if let improved { stretch = improved.stretch; seams = improved.seams; result = improved.result }
                }
                return Solution(seams: seams, result: result)
            } catch {
                lastError = error
                guard round < maximumChords else { break }
            }

            let cutVertices = loopVertices.union(seams.flatMap { $0 })
            let samples = farthestSamples(of: cutVertices.sorted(), positions: positions, count: 8)
            var best: (score: Double, chord: [Int])?
            let current = worst(seams)
            for chord in chords(among: samples, cutVertices: cutVertices, positions: positions, neighbours: neighbours) {
                let value = worst(seams + [chord])
                if value.isFinite, best == nil || value < best!.score { best = (value, chord) }
            }
            guard let best, best.score < current else { break }
            seams.append(best.chord)
        }
        throw lastError ?? FlatteningError.invalidMesh("no verified layout was found for this piece")
    }

    /// Triangle-weighted mean stretch across islands; infinite when any triangle is flipped.
    static func meanStretch(_ islands: [UVIsland], positions: [Vec3]) -> Double {
        var weighted = 0.0, triangles = 0
        for island in islands {
            let quality = PatternQualityMap.evaluate(island: island, positions: positions)
            guard quality.flippedTriangles == 0, quality.meanStretch.isFinite else { return .infinity }
            let count = island.triangles.count / 3
            weighted += quality.meanStretch * Double(count)
            triangles += count
        }
        return triangles > 0 ? weighted / Double(triangles) : .infinity
    }

    /// A verified layout for an open piece, expressed as a seam suggestion.
    static func suggestion(positions: [Vec3], triangles: [Int32], fabric: FabricProfile, visibility: SeamVisibility = .none) throws -> SeamSuggestion? {
        // A single-boundary disc that already lies flat (a planar face) needs no cuts at all.
        if OpenPieceSeams.boundaryLoops(triangles: triangles).count == 1, HandleSeams.genus(triangles: triangles) == 0,
           let flat = try? TopologyEngine.flatten(positions: positions, triangles: triangles, seams: [], fabric: fabric),
           flat.islands.count == 1, flat.islands.allSatisfy({ $0.report.passed && $0.geometryReport.areaDelta < 0.005 && $0.geometryReport.meanLocalDistortion < 0.01 }) {
            return SeamSuggestion(
                id: "open-flat", title: "No seams → 1 panel", seamPaths: [], panelCount: 1,
                worstAreaDelta: flat.islands[0].geometryReport.areaDelta,
                worstMeanLocalDistortion: flat.islands[0].geometryReport.meanLocalDistortion,
                worstStitchLengthMismatch: 0, largestPanelAreaShare: 1, normalizedSeamLength: 0, dartCount: flat.islands[0].darts.count,
                layoutScore: 0, rationale: "The piece is already flat, so it needs no cuts."
            )
        }
        guard let solution = try solve(positions: positions, triangles: triangles, fabric: fabric, visibility: visibility) else { return nil }
        let islands = solution.result.islands
        guard !islands.isEmpty, islands.allSatisfy({ $0.report.passed }) else { return nil }
        let mismatch = stitchMismatch(islands: islands, seams: solution.seams)
        let areas = islands.map(\.geometryReport.area3D)
        let total = areas.reduce(0, +)
        guard total > 0, mismatch.isFinite else { return nil }
        let length = solution.seams.reduce(0.0) { sum, path in
            sum + zip(path, path.dropFirst()).reduce(0.0) { $0 + vlength(positions[$1.1] - positions[$1.0]) }
        }
        let panels = islands.count == 1 ? "1 panel" : "\(islands.count) panels"
        let seams = solution.seams.count == 1 ? "1 seam" : "\(solution.seams.count) seams"
        return SeamSuggestion(
            id: "open-" + solution.seams.map { "\($0.first ?? 0).\($0.last ?? 0)" }.joined(separator: "-"),
            title: "\(seams) → \(panels)",
            seamPaths: solution.seams,
            panelCount: islands.count,
            worstAreaDelta: islands.map(\.geometryReport.areaDelta).max() ?? 0,
            worstMeanLocalDistortion: islands.map(\.geometryReport.meanLocalDistortion).max() ?? 0,
            worstStitchLengthMismatch: mismatch,
            largestPanelAreaShare: (areas.max() ?? 0) / total,
            normalizedSeamLength: length / total.squareRoot(),
            dartCount: islands.reduce(0) { $0 + $1.darts.count },
            layoutScore: 0,
            rationale: "Open piece: boundary loops joined into one disc, then divided by the chord and petal cuts that most reduced distortion. Every panel passed flattening verification."
        )
    }

    /// Worst per-seam length mismatch: for each seam path, the summed edge-length differences between its two
    /// flattened copies relative to the summed mean length (single short edges are too noisy to judge sewing ease).
    static func stitchMismatch(islands: [UVIsland], seams: [[Int]]) -> Double {
        let stitches = SeamSuggestionEngine.boundaryEdgeLengths(in: islands)
        return seams.map { path -> Double in
            var difference = 0.0, mean = 0.0
            for (a, b) in zip(path, path.dropFirst()) {
                guard let lengths = stitches[SurfaceCutter.edgeKey(Int32(a), Int32(b))], lengths.count == 2 else { continue }
                difference += abs(lengths[0] - lengths[1])
                mean += (lengths[0] + lengths[1]) * 0.5
            }
            return mean > 1e-12 ? difference / mean : 0
        }.max() ?? 0
    }

    /// Orange-peel cuts: shortest interior paths from the deepest interior vertex to evenly spaced boundary vertices.
    private static func petalSeams(positions: [Vec3], neighbours: [[Int]], loop: [Int], boundary: Set<Int>, petals: Int) -> [[Int]]? {
        guard loop.count >= petals else { return nil }
        let depth = dijkstra(from: Array(boundary), positions: positions, neighbours: neighbours, blocked: [])
        guard let apex = depth.distance.indices.filter({ !boundary.contains($0) && depth.distance[$0].isFinite })
            .max(by: { depth.distance[$0] < depth.distance[$1] }) else { return nil }
        let tree = dijkstra(from: [apex], positions: positions, neighbours: neighbours, blocked: boundary)
        var seams: [[Int]] = []
        for k in 0..<petals {
            var path = [loop[k * loop.count / petals]]
            guard tree.distance[path[0]].isFinite else { continue }
            while let p = tree.previous[path[path.count - 1]] { path.append(p) }
            if path.count >= 2 { seams.append(path.reversed()) }
        }
        return seams.count >= 2 ? seams : nil
    }

    /// Shortest paths over the edge graph. Blocked vertices may be reached but are never travelled through.
    private static func dijkstra(from sources: [Int], positions: [Vec3], neighbours: [[Int]], blocked: Set<Int>) -> (distance: [Double], previous: [Int?]) {
        var distance = [Double](repeating: .infinity, count: positions.count)
        var previous = [Int?](repeating: nil, count: positions.count)
        var heap: [(Double, Int)] = []
        func push(_ item: (Double, Int)) {
            heap.append(item)
            var i = heap.count - 1
            while i > 0, heap[(i - 1) / 2].0 > heap[i].0 { heap.swapAt(i, (i - 1) / 2); i = (i - 1) / 2 }
        }
        func pop() -> (Double, Int) {
            let top = heap[0]
            heap[0] = heap[heap.count - 1]
            heap.removeLast()
            var i = 0
            while true {
                var m = i
                for c in [2 * i + 1, 2 * i + 2] where c < heap.count && heap[c].0 < heap[m].0 { m = c }
                if m == i { break }
                heap.swapAt(i, m); i = m
            }
            return top
        }
        for source in sources { distance[source] = 0; push((0, source)) }
        while !heap.isEmpty {
            let (d, u) = pop()
            if d > distance[u] { continue }
            if blocked.contains(u), d > 0 { continue }
            for n in neighbours[u] {
                let nd = d + vlength(positions[n] - positions[u])
                if nd < distance[n] { distance[n] = nd; previous[n] = u; push((nd, n)) }
            }
        }
        return (distance, previous)
    }

    private static func farthestSamples(of vertices: [Int], positions: [Vec3], count: Int) -> [Int] {
        guard let first = vertices.first else { return [] }
        var chosen = [first]
        var nearest = vertices.map { vlength(positions[$0] - positions[first]) }
        while chosen.count < min(count, vertices.count) {
            guard let index = nearest.indices.max(by: { nearest[$0] < nearest[$1] }), nearest[index] > 0 else { break }
            chosen.append(vertices[index])
            for i in vertices.indices { nearest[i] = min(nearest[i], vlength(positions[vertices[i]] - positions[vertices[index]])) }
        }
        return chosen
    }

    private static func chords(among samples: [Int], cutVertices: Set<Int>, positions: [Vec3], neighbours: [[Int]]) -> [[Int]] {
        var found: [[Int]] = []
        let sampleSet = Set(samples)
        for source in samples {
            var distance = [Int: Double]()
            var previous = [Int: Int]()
            var heap = [(Double, Int)]()
            distance[source] = 0
            heap.append((0, source))
            while !heap.isEmpty {
                heap.sort { $0.0 > $1.0 }
                let (d, u) = heap.removeLast()
                if d > distance[u, default: .infinity] { continue }
                if u != source, sampleSet.contains(u), u > source {
                    var path = [u]
                    while let p = previous[path[path.count - 1]] { path.append(p) }
                    if path.count >= 3 { found.append(path.reversed()) }
                }
                if u != source, cutVertices.contains(u) { continue }
                for n in neighbours[u] {
                    // Interior-only travel keeps the chord from running along an existing cut.
                    if cutVertices.contains(n), !sampleSet.contains(n) { continue }
                    let nd = d + vlength(positions[n] - positions[u])
                    if nd < distance[n, default: .infinity] { distance[n] = nd; previous[n] = u; heap.append((nd, n)) }
                }
            }
        }
        return found
    }
}

import Foundation

/// Constructions for recognised primitives: one panel per flat face, end caps plus a side band, or identical meridian gores.
enum PrimitiveSplitter {
    /// Builds a component from a subset of triangles, re-indexing vertices and keeping the source vertex map.
    static func subset(positions: [Vec3], triangles: [Int32], faces: [Int], label: String) -> MeshComponent? {
        guard !faces.isEmpty else { return nil }
        var remap: [Int32: Int32] = [:]
        var newPositions: [Vec3] = [], origin: [Int] = [], newTriangles: [Int32] = []
        for f in faces {
            for k in 0..<3 {
                let v = triangles[3 * f + k]
                if let mapped = remap[v] { newTriangles.append(mapped) } else {
                    let mapped = Int32(newPositions.count)
                    remap[v] = mapped
                    newPositions.append(positions[Int(v)]); origin.append(Int(v))
                    newTriangles.append(mapped)
                }
            }
        }
        return MeshComponent(id: 0, positions: newPositions, triangles: newTriangles, sourceVertices: origin, anatomicalLabel: label)
    }

    private static func numbered(_ parts: [MeshComponent]) -> [MeshComponent] {
        parts.enumerated().map { MeshComponent(id: $0.offset, positions: $0.element.positions, triangles: $0.element.triangles, sourceVertices: $0.element.sourceVertices, anatomicalLabel: $0.element.anatomicalLabel) }
    }

    /// One panel per flat face; opposite and equal faces are mirrored copies, which keeps the pattern uniform.
    static func facetComponents(positions: [Vec3], triangles: [Int32]) -> [MeshComponent] {
        let set = PrimitiveDetector.clusterFacets(positions: positions, triangles: triangles)
        let parts = set.facets.enumerated().compactMap { index, facet in
            subset(positions: positions, triangles: triangles, faces: facet.faces, label: "Face \(index + 1)")
        }
        return numbered(parts)
    }

    private static func faceNormalAndCentre(_ f: Int, positions: [Vec3], triangles: [Int32]) -> (Vec3, Vec3) {
        let a = positions[Int(triangles[3 * f])], b = positions[Int(triangles[3 * f + 1])], c = positions[Int(triangles[3 * f + 2])]
        let cross = vcross(b - a, c - a)
        let length = vlength(cross)
        return (length > 1e-18 ? cross / length : .zero, (a + b + c) / 3)
    }

    /// Splits flat end caps (normal along the axis, near an end) from everything else.
    static func capFaces(positions: [Vec3], triangles: [Int32], axis: Vec3, center: Vec3) -> (low: [Int], high: [Int], rest: [Int]) {
        let count = triangles.count / 3
        let heights = positions.map { vdot($0 - center, axis) }
        guard let lo = heights.min(), let hi = heights.max(), hi > lo else { return ([], [], Array(0..<count)) }
        let reach = 0.04 * (hi - lo)
        var low: [Int] = [], high: [Int] = [], rest: [Int] = []
        for f in 0..<count {
            let (n, c) = faceNormalAndCentre(f, positions: positions, triangles: triangles)
            let h = vdot(c - center, axis)
            if abs(vdot(n, axis)) > PrimitiveDetector.capNormalCosine, h < lo + reach { low.append(f) }
            else if abs(vdot(n, axis)) > PrimitiveDetector.capNormalCosine, h > hi - reach { high.append(f) }
            else { rest.append(f) }
        }
        // Polar fans of round bodies are not caps: a real cap carries a meaningful share of the surface.
        func area(_ faces: [Int]) -> Double {
            faces.reduce(0) { total, f in
                let a = positions[Int(triangles[3 * f])], b = positions[Int(triangles[3 * f + 1])], c = positions[Int(triangles[3 * f + 2])]
                return total + 0.5 * vlength(vcross(b - a, c - a))
            }
        }
        let total = area(Array(0..<count))
        var keptLow = low, keptHigh = high
        if area(low) < 0.03 * total { rest += low; keptLow = [] }
        if area(high) < 0.03 * total { rest += high; keptHigh = [] }
        return (keptLow, keptHigh, rest.sorted())
    }

    /// Side band plus the flat end caps: a rectangle (or trapezoid) wrapped around two discs.
    static func tubeComponents(positions: [Vec3], triangles: [Int32], axis: Vec3, center: Vec3) -> [MeshComponent] {
        let caps = capFaces(positions: positions, triangles: triangles, axis: axis, center: center)
        let parts = [
            subset(positions: positions, triangles: triangles, faces: caps.rest, label: "Side band"),
            subset(positions: positions, triangles: triangles, faces: caps.low, label: "Bottom cap"),
            subset(positions: positions, triangles: triangles, faces: caps.high, label: "Top cap")
        ].compactMap { $0 }
        return numbered(parts)
    }

    /// Cuts along `count` evenly spaced edge paths from pole to pole, so neighbouring gores share exactly the same boundary edges.
    /// Returns nil when a path cannot be walked to the far pole, so the caller can fall back to angular sectors.
    static func meridianCut(positions: [Vec3], triangles: [Int32], axis: Vec3, center: Vec3, count: Int) -> [MeshComponent]? {
        let reference = abs(axis.x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)
        let u = vcross(axis, reference) / vlength(vcross(axis, reference))
        let v = vcross(axis, u)
        let heights = positions.map { vdot($0 - center, axis) }
        let angles = positions.map { p -> Double in
            let d = p - center
            return atan2(vdot(d, v), vdot(d, u))
        }
        guard let bottom = heights.indices.min(by: { heights[$0] < heights[$1] }),
              let top = heights.indices.max(by: { heights[$0] < heights[$1] }), bottom != top else { return nil }
        var neighbours = [Set<Int>](repeating: [], count: positions.count)
        for t in stride(from: 0, to: triangles.count, by: 3) {
            for k in 0..<3 {
                let a = Int(triangles[t + k]), b = Int(triangles[t + (k + 1) % 3])
                neighbours[a].insert(b); neighbours[b].insert(a)
            }
        }
        func deviation(_ a: Double, _ b: Double) -> Double {
            var d = abs(a - b).truncatingRemainder(dividingBy: 2 * .pi)
            if d > .pi { d = 2 * .pi - d }
            return d
        }
        let epsilon = 1e-9 * max(1, (heights.max() ?? 1) - (heights.min() ?? 0))
        var seams: [[Int]] = []
        // Paths may meet only at the poles; shared interior vertices would pinch a gore's outline.
        var used = Set<Int>([bottom, top])
        var claimed = Set<Int>()
        for k in 0..<count {
            let target = -Double.pi + 2 * Double.pi * (Double(k) + 0.5) / Double(count)
            // Dijkstra with a penalty for straying from the target meridian; claimed vertices are blocked.
            var dist = [Double](repeating: .infinity, count: positions.count)
            var previous = [Int](repeating: -1, count: positions.count)
            var done = Set<Int>()
            dist[bottom] = 0
            var frontier: [Int] = [bottom]
            while let current = frontier.min(by: { dist[$0] < dist[$1] || (dist[$0] == dist[$1] && $0 < $1) }) {
                frontier.removeAll { $0 == current }
                if current == top { break }
                if !done.insert(current).inserted { continue }
                for n in neighbours[current] where !done.contains(n) && (n == top || !claimed.contains(n)) {
                    let length = vlength(positions[n] - positions[current])
                    let weight = n == top ? 0 : deviation(angles[n], target)
                    let candidate = dist[current] + length * (1 + 4 * weight)
                    if candidate < dist[n] {
                        if dist[n] == .infinity { frontier.append(n) }
                        dist[n] = candidate; previous[n] = current
                    }
                }
            }
            guard previous[top] >= 0 else { return nil }
            var path = [top]
            while path.last! != bottom { path.append(previous[path.last!]) }
            path.reverse()
            // Reserve the path's vertices and their neighbours so the next meridian keeps at least one edge of clearance.
            for vertex in path where !used.contains(vertex) { claimed.insert(vertex); claimed.formUnion(neighbours[vertex]) }
            claimed.subtract([bottom, top])
            seams.append(path)
        }
        guard var parts = try? MeshComponentSplitter.split(positions: positions, triangles: triangles, seams: seams), parts.count == count else { return nil }
        parts = parts.enumerated().map { MeshComponent(id: $0.offset, positions: $0.element.positions, triangles: $0.element.triangles, sourceVertices: $0.element.sourceVertices, anatomicalLabel: "Gore \($0.offset + 1)") }
        return parts
    }

    /// `count` identical gores running pole to pole (orange-peel construction); flat end caps stay separate discs.
    static func meridianGoreComponents(positions: [Vec3], triangles: [Int32], axis: Vec3, center: Vec3, count: Int) -> [MeshComponent] {
        let caps = capFaces(positions: positions, triangles: triangles, axis: axis, center: center)
        if caps.low.isEmpty, caps.high.isEmpty,
           let cut = meridianCut(positions: positions, triangles: triangles, axis: axis, center: center, count: max(count, 2)) { return cut }
        let reference = abs(axis.x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)
        let u = vcross(axis, reference) / vlength(vcross(axis, reference))
        let v = vcross(axis, u)
        var sectors = [[Int]](repeating: [], count: max(count, 2))
        let width = 2 * Double.pi / Double(sectors.count)
        for f in caps.rest {
            let c = faceNormalAndCentre(f, positions: positions, triangles: triangles).1 - center
            var angle = atan2(vdot(c, v), vdot(c, u))
            if angle < 0 { angle += 2 * .pi }
            sectors[min(sectors.count - 1, Int(angle / width))].append(f)
        }
        var parts: [MeshComponent] = []
        for (i, faces) in sectors.enumerated() {
            if let part = subset(positions: positions, triangles: triangles, faces: faces, label: "Gore \(i + 1)") { parts.append(part) }
        }
        if let part = subset(positions: positions, triangles: triangles, faces: caps.low, label: "Bottom cap") { parts.append(part) }
        if let part = subset(positions: positions, triangles: triangles, faces: caps.high, label: "Top cap") { parts.append(part) }
        return numbered(parts)
    }
}

/// Seam placement driven by a recognised primitive, instead of the generic search.
enum PrimitiveSeams {
    /// One straight seam down a tube's side band, from one end ring to the other, steered away from conspicuous regions.
    /// Returns nil unless the band flattens to a single verified panel with the seam, so callers can fall back to the generic solver.
    static func tubeBandSuggestion(positions: [Vec3], triangles: [Int32], fabric: FabricProfile, visibility: SeamVisibility) -> SeamSuggestion? {
        let loops = OpenPieceSeams.boundaryLoops(triangles: triangles)
        guard loops.count == 2, HandleSeams.genus(triangles: triangles) == 0 else { return nil }
        var neighbours = [Set<Int>](repeating: [], count: positions.count)
        for t in stride(from: 0, to: triangles.count, by: 3) {
            for k in 0..<3 {
                let a = Int(triangles[t + k]), b = Int(triangles[t + (k + 1) % 3])
                neighbours[a].insert(b); neighbours[b].insert(a)
            }
        }
        var distance = [Double](repeating: .infinity, count: positions.count)
        var previous = [Int?](repeating: nil, count: positions.count)
        var done = [Bool](repeating: false, count: positions.count)
        for v in loops[0] { distance[v] = 0 }
        while true {
            var u = -1
            for v in positions.indices where !done[v] && distance[v].isFinite && (u < 0 || distance[v] < distance[u]) { u = v }
            if u < 0 { break }
            done[u] = true
            for w in neighbours[u] where !done[w] {
                let mid = (positions[u] + positions[w]) * 0.5
                // Edges inside a conspicuous region cost up to 4x, so the seam routes around faces and other detail.
                let cost = vlength(positions[w] - positions[u]) * (1 + 3 * visibility.weight(at: mid))
                if distance[u] + cost < distance[w] { distance[w] = distance[u] + cost; previous[w] = u }
            }
        }
        let far = Set(loops[1])
        guard let end = far.filter({ distance[$0].isFinite }).min(by: { distance[$0] < distance[$1] || (distance[$0] == distance[$1] && $0 < $1) }) else { return nil }
        var path = [end]
        while let p = previous[path[path.count - 1]] { path.append(p) }
        path.reverse()
        guard path.count >= 2, let flat = try? TopologyEngine.flatten(positions: positions, triangles: triangles, seams: [path], fabric: fabric),
              flat.islands.count == 1, flat.islands.allSatisfy({ $0.report.passed }) else { return nil }
        let island = flat.islands[0]
        let length = zip(path, path.dropFirst()).reduce(0.0) { $0 + vlength(positions[$1.1] - positions[$1.0]) }
        let area = island.geometryReport.area3D
        return SeamSuggestion(
            id: "tube-\(path.first ?? 0).\(path.last ?? 0)", title: "1 seam → 1 panel", seamPaths: [path], panelCount: 1,
            worstAreaDelta: island.geometryReport.areaDelta, worstMeanLocalDistortion: island.geometryReport.meanLocalDistortion,
            worstStitchLengthMismatch: OpenPieceSeams.stitchMismatch(islands: flat.islands, seams: [path]),
            largestPanelAreaShare: 1, normalizedSeamLength: area > 0 ? length / area.squareRoot() : 0, dartCount: island.darts.count, layoutScore: 0,
            rationale: "Cylinder side band: one straight seam end to end, routed away from conspicuous regions; the caps are set in with a circular seam."
        )
    }
}

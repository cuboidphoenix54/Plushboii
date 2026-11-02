import Foundation

struct SeamSuggestion: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let seamPaths: [[Int]]
    let panelCount: Int
    let worstAreaDelta: Double
    let worstMeanLocalDistortion: Double
    let worstStitchLengthMismatch: Double
    let largestPanelAreaShare: Double
    let normalizedSeamLength: Double
    let dartCount: Int
    let layoutScore: Double
    let rationale: String
}

enum SeamSuggestionError: LocalizedError {
    case invalidMesh

    var errorDescription: String? {
        switch self {
        case .invalidMesh:
            "The mesh topology is invalid, so seam suggestions could not be calculated."
        }
    }
}

enum SeamSuggestionEngine {
    private struct Proposal {
        let paths: [[Int]]
        let panelCount: Int
        let worstAreaDelta: Double
        let worstMeanLocalDistortion: Double
        let worstStitchLengthMismatch: Double
        let largestPanelAreaShare: Double
        let normalizedSeamLength: Double
        let dartCount: Int
        let score: Double
        let id: String
    }

    private struct Route {
        let axis: Int
        let sector: Int
        let path: [Int]
        let length: Double

        var id: String { "a\(axis + 1)-s\(sector + 1)" }
        var edgeSet: Set<UInt64> {
            Set(zip(path, path.dropFirst()).map { SurfaceCutter.edgeKey(Int32($0), Int32($1)) })
        }
    }

    static func suggest(
        positions: [Vec3],
        triangles: [Int32],
        fabric: FabricProfile = .none,
        maximumSuggestions: Int = 3
    ) throws -> [SeamSuggestion] {
        guard positions.count >= 3, triangles.count >= 3, triangles.count.isMultiple(of: 3),
              positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              triangles.allSatisfy({ $0 >= 0 && Int($0) < positions.count }),
              maximumSuggestions > 0
        else {
            throw SeamSuggestionError.invalidMesh
        }
        try fabric.validated()

        if !OpenPieceSeams.boundaryLoops(triangles: triangles).isEmpty || HandleSeams.genus(triangles: triangles) > 0 {
            guard let suggestion = try OpenPieceSeams.suggestion(positions: positions, triangles: triangles, fabric: fabric) else { return [] }
            return [suggestion]
        }

        let graph = try EdgeGraph(vertexCount: positions.count, triangles: triangles)
        let axes = try principalAxes(for: positions, triangles: triangles)
        let routes = candidateRoutes(axes: axes, positions: positions, graph: graph)
        guard !routes.isEmpty else { return [] }

        var uniqueRoutes: [Route] = []
        var seenPaths = Set<[Int]>()
        for route in routes {
            let canonical = canonicalPath(route.path)
            if seenPaths.insert(canonical).inserted {
                uniqueRoutes.append(route)
            }
        }
        let selectedRoutes = diverseRouteSet(uniqueRoutes, limit: 5)

        let surfaceArea = totalSurfaceArea(positions: positions, triangles: triangles)
        guard surfaceArea.isFinite, surfaceArea > 0 else { throw SeamSuggestionError.invalidMesh }
        let lengthScale = surfaceArea.squareRoot()

        var proposals: [Proposal] = []
        let combinationCount = 1 << selectedRoutes.count
        for mask in 1..<combinationCount {
            let selected = selectedRoutes.enumerated().compactMap { index, route in
                mask & (1 << index) == 0 ? nil : route
            }
            guard selected.count <= 3 else { continue }
            let paths = selected.map(\.path)
            let pathEdges = paths.map { path in
                Set(zip(path, path.dropFirst()).map { SurfaceCutter.edgeKey(Int32($0), Int32($1)) })
            }
            let uniqueEdgeCount = pathEdges.reduce(0) { $0 + $1.count }
            let combinedEdgeCount = pathEdges.reduce(into: Set<UInt64>()) { $0.formUnion($1) }.count
            guard uniqueEdgeCount == combinedEdgeCount else { continue }
            let id = selected.map(\.id).joined(separator: "-")

            guard let flattened = try? TopologyEngine.flatten(
                positions: positions,
                triangles: triangles,
                seams: paths,
                fabric: fabric
            ) else {
                continue
            }

            let islands = flattened.islands
            guard !islands.isEmpty, islands.allSatisfy({ $0.report.passed }) else { continue }
            let cutEdges = pathEdges.reduce(into: Set<UInt64>()) { $0.formUnion($1) }
            let stitchLengths = boundaryEdgeLengths(in: islands)
            guard cutEdges.allSatisfy({ stitchLengths[$0]?.count == 2 }) else { continue }
            // The audit also covers cuts the flattener adds itself, which `cutEdges` does not list.
            let auditedMismatch = StitchAudit.audit(islands).worstMismatch
            let chosenMismatch = cutEdges.compactMap { edge -> Double? in
                guard let lengths = stitchLengths[edge], lengths.count == 2 else { return nil }
                let meanLength = (lengths[0] + lengths[1]) * 0.5
                guard meanLength.isFinite, meanLength > 1e-12 else { return .infinity }
                return abs(lengths[0] - lengths[1]) / meanLength
            }.max() ?? .infinity
            let worstStitchMismatch = max(chosenMismatch, auditedMismatch)
            let areas = islands.map(\.geometryReport.area3D)
            let totalArea = areas.reduce(0, +)
            guard totalArea.isFinite, totalArea > 0 else { continue }
            let worstAreaDelta = islands.map(\.geometryReport.areaDelta).max() ?? .infinity
            let worstLocal = islands.map(\.geometryReport.meanLocalDistortion).max() ?? .infinity
            let largestAreaShare = (areas.max() ?? 0) / totalArea
            let seamLength = paths.reduce(0.0) { partial, path in
                partial + zip(path, path.dropFirst()).reduce(0.0) { length, edge in
                    length + vlength(positions[edge.1] - positions[edge.0])
                }
            }
            let normalizedLength = seamLength / lengthScale
            let darts = islands.reduce(0) { $0 + $1.darts.count }
            guard [worstAreaDelta, worstLocal, worstStitchMismatch, largestAreaShare, normalizedLength]
                .allSatisfy(\.isFinite) else {
                continue
            }

            let score = 4 * worstAreaDelta
                + worstLocal
                + 1.5 * worstStitchMismatch
                + 0.5 * largestAreaShare
                + 0.08 * normalizedLength
                + 0.2 * Double(islands.count - 1)
                + 0.12 * Double(darts)
            proposals.append(Proposal(
                paths: paths,
                panelCount: islands.count,
                worstAreaDelta: worstAreaDelta,
                worstMeanLocalDistortion: worstLocal,
                worstStitchLengthMismatch: worstStitchMismatch,
                largestPanelAreaShare: largestAreaShare,
                normalizedSeamLength: normalizedLength,
                dartCount: darts,
                score: score,
                id: id
            ))
        }

        return proposals
            .sorted { $0.score == $1.score ? $0.id < $1.id : $0.score < $1.score }
            .prefix(maximumSuggestions)
            .map { proposal in
                let panels = proposal.panelCount == 1 ? "1 panel" : "\(proposal.panelCount) panels"
                let seams = proposal.paths.count == 1 ? "1 seam" : "\(proposal.paths.count) seams"
                return SeamSuggestion(
                    id: proposal.id,
                    title: "\(seams) → \(panels)",
                    seamPaths: proposal.paths,
                    panelCount: proposal.panelCount,
                    worstAreaDelta: proposal.worstAreaDelta,
                    worstMeanLocalDistortion: proposal.worstMeanLocalDistortion,
                    worstStitchLengthMismatch: proposal.worstStitchLengthMismatch,
                    largestPanelAreaShare: proposal.largestPanelAreaShare,
                    normalizedSeamLength: proposal.normalizedSeamLength,
                    dartCount: proposal.dartCount,
                    layoutScore: proposal.score,
                    rationale: "Every panel passed flattening verification. Every cut edge has two corresponding pattern edges; their measured length mismatch is included in the ranking."
                )
            }
    }

    private static func candidateRoutes(axes: [Vec3], positions: [Vec3], graph: EdgeGraph) -> [Route] {
        var routes: [Route] = []
        for (axisIndex, axis) in axes.enumerated() {
            guard
                let start = positions.indices.min(by: { vdot(positions[$0], axis) < vdot(positions[$1], axis) }),
                let end = positions.indices.max(by: { vdot(positions[$0], axis) < vdot(positions[$1], axis) }),
                start != end
            else {
                continue
            }

            let projections = positions.map { vdot($0, axis) }
            let axialCenter = (projections[start] + projections[end]) * 0.5
            let axialExtent = projections[end] - projections[start]
            let fromStart = graph.shortestPaths(from: start, positions: positions)
            let fromEnd = graph.shortestPaths(from: end, positions: positions)
            let equatorialVertices = positions.indices.filter {
                $0 != start && $0 != end && abs(projections[$0] - axialCenter) <= axialExtent * 0.25
            }
            let waypointPool = equatorialVertices.isEmpty
                ? positions.indices.filter { $0 != start && $0 != end }
                : equatorialVertices
            guard !waypointPool.isEmpty else { continue }

            let seed = [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)]
                .min { abs(vdot($0, axis)) < abs(vdot($1, axis)) }!
            var firstRadial = vcross(axis, seed)
            let radialLength = vlength(firstRadial)
            guard radialLength.isFinite, radialLength > 1e-12 else { continue }
            firstRadial /= radialLength
            let secondRadial = vcross(axis, firstRadial)
            let directions = [firstRadial, secondRadial, -firstRadial, -secondRadial]

            for (sector, direction) in directions.enumerated() {
                guard let waypoint = waypointPool.max(by: { lhs, rhs in
                    let lhsOffset = positions[lhs] - positions[start]
                    let rhsOffset = positions[rhs] - positions[start]
                    let lhsRadial = lhsOffset - axis * vdot(lhsOffset, axis)
                    let rhsRadial = rhsOffset - axis * vdot(rhsOffset, axis)
                    let lhsScore = vdot(lhsRadial, direction)
                    let rhsScore = vdot(rhsRadial, direction)
                    return lhsScore == rhsScore ? lhs > rhs : lhsScore < rhsScore
                }),
                let firstHalf = fromStart.path(to: waypoint),
                let endToWaypoint = fromEnd.path(to: waypoint)
                else {
                    continue
                }

                let waypointToEnd = endToWaypoint.reversed()
                let path = firstHalf + waypointToEnd.dropFirst()
                guard path.count >= 3, Set(path).count == path.count, graph.isInteriorPath(path) else { continue }
                let length = zip(path, path.dropFirst()).reduce(0.0) { total, edge in
                    total + vlength(positions[edge.1] - positions[edge.0])
                }
                guard length.isFinite, length > 0 else { continue }
                routes.append(Route(axis: axisIndex, sector: sector, path: path, length: length))
            }
        }
        return routes
    }

    private static func diverseRouteSet(_ routes: [Route], limit: Int) -> [Route] {
        var selected: [Route] = []
        for axis in 0..<3 {
            let quota = axis == 0 ? 3 : 1
            let axisRoutes = routes.filter { $0.axis == axis }.sorted {
                $0.length == $1.length ? $0.id < $1.id : $0.length < $1.length
            }
            var added = 0
            for route in axisRoutes where selected.count < limit && added < quota {
                let routeEdges = route.edgeSet
                let overlapsExisting = selected.contains { existing in
                    let existingEdges = existing.edgeSet
                    let smallerCount = min(routeEdges.count, existingEdges.count)
                    guard smallerCount > 0 else { return false }
                    return Double(routeEdges.intersection(existingEdges).count) / Double(smallerCount) > 0.75
                }
                guard !overlapsExisting else { continue }
                selected.append(route)
                added += 1
            }
        }
        return selected
    }

    private static func principalAxes(for positions: [Vec3], triangles: [Int32]) throws -> [Vec3] {
        let faces = stride(from: 0, to: triangles.count, by: 3).map { corner in
            let a = positions[Int(triangles[corner])]
            let b = positions[Int(triangles[corner + 1])]
            let c = positions[Int(triangles[corner + 2])]
            return (a: a, b: b, c: c, area: 0.5 * vlength(vcross(b - a, c - a)))
        }
        let surfaceArea = faces.reduce(0.0) { $0 + $1.area }
        guard surfaceArea.isFinite, surfaceArea > 0,
              faces.allSatisfy({ $0.area.isFinite && $0.area > 0 }) else {
            throw SeamSuggestionError.invalidMesh
        }
        let centroid = faces.reduce(Vec3.zero) { total, face in
            total + (face.a + face.b + face.c) * (face.area / 3)
        } / surfaceArea
        var covarianceColumns = [Vec3](repeating: .zero, count: 3)
        func accumulateOuterProduct(_ vector: Vec3, scale: Double) {
            covarianceColumns[0] += vector * (vector.x * scale)
            covarianceColumns[1] += vector * (vector.y * scale)
            covarianceColumns[2] += vector * (vector.z * scale)
        }
        for face in faces {
            let a = face.a - centroid
            let b = face.b - centroid
            let c = face.c - centroid
            let scale = face.area / 12
            accumulateOuterProduct(a, scale: scale)
            accumulateOuterProduct(b, scale: scale)
            accumulateOuterProduct(c, scale: scale)
            accumulateOuterProduct(a + b + c, scale: scale)
        }

        var matrix = [
            [covarianceColumns[0].x, covarianceColumns[1].x, covarianceColumns[2].x],
            [covarianceColumns[0].y, covarianceColumns[1].y, covarianceColumns[2].y],
            [covarianceColumns[0].z, covarianceColumns[1].z, covarianceColumns[2].z],
        ]
        var eigenvectors = [
            [1.0, 0, 0],
            [0, 1.0, 0],
            [0, 0, 1.0],
        ]
        for _ in 0..<32 {
            var p = 0
            var q = 1
            var largest = abs(matrix[p][q])
            for (candidateP, candidateQ) in [(0, 2), (1, 2)] {
                if abs(matrix[candidateP][candidateQ]) > largest {
                    p = candidateP
                    q = candidateQ
                    largest = abs(matrix[p][q])
                }
            }
            let scale = max(
                max(abs(matrix[0][0]), abs(matrix[1][1])),
                max(abs(matrix[2][2]), Double.leastNormalMagnitude)
            )
            guard largest > scale * 1e-14 else { break }

            let tau = (matrix[q][q] - matrix[p][p]) / (2 * matrix[p][q])
            let tangent = (tau >= 0 ? 1.0 : -1.0) / (abs(tau) + (1 + tau * tau).squareRoot())
            let cosine = 1 / (1 + tangent * tangent).squareRoot()
            let sine = tangent * cosine
            let app = matrix[p][p]
            let aqq = matrix[q][q]
            let apq = matrix[p][q]
            matrix[p][p] = app - tangent * apq
            matrix[q][q] = aqq + tangent * apq
            matrix[p][q] = 0
            matrix[q][p] = 0

            for index in 0..<3 where index != p && index != q {
                let aip = matrix[index][p]
                let aiq = matrix[index][q]
                matrix[index][p] = cosine * aip - sine * aiq
                matrix[p][index] = matrix[index][p]
                matrix[index][q] = sine * aip + cosine * aiq
                matrix[q][index] = matrix[index][q]
            }
            for index in 0..<3 {
                let vip = eigenvectors[index][p]
                let viq = eigenvectors[index][q]
                eigenvectors[index][p] = cosine * vip - sine * viq
                eigenvectors[index][q] = sine * vip + cosine * viq
            }
        }

        let order = (0..<3).sorted { lhs, rhs in
            let leftValue = matrix[lhs][lhs]
            let rightValue = matrix[rhs][rhs]
            if leftValue == rightValue { return lhs < rhs }
            return leftValue > rightValue
        }
        return order.compactMap { index in
            var axis = Vec3(eigenvectors[0][index], eigenvectors[1][index], eigenvectors[2][index])
            let length = vlength(axis)
            guard length.isFinite, length > 1e-12 else { return nil }
            axis /= length
            canonicalizeSign(&axis)
            return axis
        }
    }

    private static func canonicalizeSign(_ vector: inout Vec3) {
        let components = [vector.x, vector.y, vector.z]
        guard let dominant = components.indices.max(by: { abs(components[$0]) < abs(components[$1]) }),
              components[dominant] < 0
        else {
            return
        }
        vector = -vector
    }

    private static func canonicalPath(_ path: [Int]) -> [Int] {
        let reversed = Array(path.reversed())
        return path.lexicographicallyPrecedes(reversed) ? path : reversed
    }

    private static func totalSurfaceArea(positions: [Vec3], triangles: [Int32]) -> Double {
        stride(from: 0, to: triangles.count, by: 3).reduce(0.0) { area, corner in
            let a = positions[Int(triangles[corner])]
            let b = positions[Int(triangles[corner + 1])]
            let c = positions[Int(triangles[corner + 2])]
            return area + 0.5 * vlength(vcross(b - a, c - a))
        }
    }

    static func boundaryEdgeLengths(in islands: [UVIsland]) -> [UInt64: [Double]] {
        var lengths: [UInt64: [Double]] = [:]
        for island in islands {
            var edgeCounts: [UInt64: Int] = [:]
            for corner in stride(from: 0, to: island.triangles.count, by: 3) {
                for index in 0..<3 {
                    let a = island.triangles[corner + index]
                    let b = island.triangles[corner + (index + 1) % 3]
                    edgeCounts[SurfaceCutter.edgeKey(a, b), default: 0] += 1
                }
            }
            for (edge, count) in edgeCounts where count == 1 {
                let a = Int(edge >> 32)
                let b = Int(edge & 0xFFFF_FFFF)
                let sourceEdge = SurfaceCutter.edgeKey(
                    Int32(island.sourceVertex[a]),
                    Int32(island.sourceVertex[b])
                )
                let uvLength = vlength(island.uv[a] - island.uv[b])
                lengths[sourceEdge, default: []].append(uvLength)
            }
        }
        return lengths
    }

    private struct EdgeGraph {
        let offsets: [Int]
        let neighbours: [Int32]
        let interiorEdges: Set<UInt64>

        init(vertexCount: Int, triangles: [Int32]) throws {
            var edgeCounts: [UInt64: Int] = [:]
            for corner in stride(from: 0, to: triangles.count, by: 3) {
                let vertices = [Int(triangles[corner]), Int(triangles[corner + 1]), Int(triangles[corner + 2])]
                guard Set(vertices).count == 3 else { throw SeamSuggestionError.invalidMesh }
                for index in 0..<3 {
                    let a = triangles[corner + index]
                    let b = triangles[corner + (index + 1) % 3]
                    let key = SurfaceCutter.edgeKey(a, b)
                    edgeCounts[key, default: 0] += 1
                    guard edgeCounts[key, default: 0] <= 2 else { throw SeamSuggestionError.invalidMesh }
                }
            }
            let interiorEdges = Set(edgeCounts.compactMap { $0.value == 2 ? $0.key : nil })
            var offsets = [Int](repeating: 0, count: vertexCount + 1)
            for key in interiorEdges {
                let a = Int(UInt32(truncatingIfNeeded: key >> 32))
                let b = Int(UInt32(truncatingIfNeeded: key))
                offsets[a + 1] += 1
                offsets[b + 1] += 1
            }
            for vertex in 0..<vertexCount { offsets[vertex + 1] += offsets[vertex] }

            var cursor = offsets
            var neighbours = [Int32](repeating: 0, count: offsets[vertexCount])
            for key in interiorEdges.sorted() {
                let a = Int32(truncatingIfNeeded: key >> 32)
                let b = Int32(truncatingIfNeeded: key)
                neighbours[cursor[Int(a)]] = b
                cursor[Int(a)] += 1
                neighbours[cursor[Int(b)]] = a
                cursor[Int(b)] += 1
            }

            self.offsets = offsets
            self.neighbours = neighbours
            self.interiorEdges = interiorEdges
        }

        func isInteriorPath(_ path: [Int]) -> Bool {
            zip(path, path.dropFirst()).allSatisfy {
                interiorEdges.contains(SurfaceCutter.edgeKey(Int32($0), Int32($1)))
            }
        }

        func shortestPaths(from start: Int, positions: [Vec3]) -> ShortestPaths {
            var distances = [Double](repeating: .infinity, count: positions.count)
            var previous = [Int32](repeating: -1, count: positions.count)
            var heap = NodeHeap()
            distances[start] = 0
            heap.push(priority: 0, node: start)

            while let (distance, vertex) = heap.pop() {
                guard distance <= distances[vertex] else { continue }
                for edge in offsets[vertex]..<offsets[vertex + 1] {
                    let neighbour = Int(neighbours[edge])
                    guard interiorEdges.contains(SurfaceCutter.edgeKey(Int32(vertex), Int32(neighbour))) else { continue }
                    let candidate = distance + vlength(positions[neighbour] - positions[vertex])
                    if candidate < distances[neighbour] {
                        distances[neighbour] = candidate
                        previous[neighbour] = Int32(vertex)
                        heap.push(priority: candidate, node: neighbour)
                    }
                }
            }
            return ShortestPaths(source: start, distances: distances, previous: previous)
        }
    }

    private struct ShortestPaths {
        let source: Int
        let distances: [Double]
        let previous: [Int32]

        func path(to goal: Int) -> [Int]? {
            guard distances.indices.contains(goal), distances[goal].isFinite else { return nil }
            var path = [goal]
            var vertex = goal
            while vertex != source {
                let parent = Int(previous[vertex])
                guard parent >= 0 else { return nil }
                path.append(parent)
                vertex = parent
            }
            return path.reversed()
        }
    }
}

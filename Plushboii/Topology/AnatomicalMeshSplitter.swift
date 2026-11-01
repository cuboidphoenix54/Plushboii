import Foundation
import simd

enum AnatomicalAxis: String, Codable, CaseIterable, Sendable {
    case x
    case y
    case z

    func coordinate(of point: Vec3) -> Double {
        switch self {
        case .x: point.x
        case .y: point.y
        case .z: point.z
        }
    }
}

struct AnatomicalCut: Codable, Equatable, Sendable {
    let axis: AnatomicalAxis
    /// Position along the source mesh's axis-aligned bounds, in 0...1.
    let normalizedPosition: Double
    let boundary: String
    let negativeRegion: String
    let positiveRegion: String
    let confidence: Double
}

/// An oriented plane: signed distance is `dot(normal, point) - offset` with a unit normal.
struct CutPlane: Sendable, Equatable {
    let normal: Vec3
    let offset: Double

    init(axis: AnatomicalAxis, coordinate: Double) {
        switch axis {
        case .x: normal = Vec3(1, 0, 0)
        case .y: normal = Vec3(0, 1, 0)
        case .z: normal = Vec3(0, 0, 1)
        }
        offset = coordinate
    }

    init?(through point: Vec3, normal direction: Vec3) {
        let length = vlength(direction)
        guard length.isFinite, length > 1e-12, point.x.isFinite, point.y.isFinite, point.z.isFinite else { return nil }
        normal = direction / length
        offset = vdot(normal, point)
    }

    func signedDistance(to point: Vec3) -> Double { vdot(normal, point) - offset }
}

struct AnatomicalCutPlan: Equatable, Sendable {
    let summary: String
    let cuts: [AnatomicalCut]
}

enum AnatomicalMeshSplitter {
    static let maximumFragmentTriangles = 8
    static let fragmentAreaFraction = 1e-4

    private struct Edge: Hashable {
        let lower: Int
        let upper: Int

        init(_ a: Int, _ b: Int) {
            lower = min(a, b)
            upper = max(a, b)
        }
    }

    private enum VertexKey: Hashable {
        case source(Int)
        case intersection(Edge)
    }

    private struct ClippedVertex {
        let key: VertexKey
        let point: Vec3
    }

    private struct Mesh {
        let positions: [Vec3]
        let triangles: [Int32]
        let sourceVertices: [Int]
    }

    static func split(
        positions: [Vec3],
        triangles: [Int32],
        cuts: [AnatomicalCut]
    ) throws -> [MeshComponent] {
        guard positions.count >= 3, triangles.count >= 3, triangles.count.isMultiple(of: 3),
              positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              triangles.allSatisfy({ $0 >= 0 && Int($0) < positions.count }),
              !cuts.isEmpty, cuts.count <= 8,
              cuts.allSatisfy({
                  $0.normalizedPosition.isFinite
                      && $0.normalizedPosition > 0
                      && $0.normalizedPosition < 1
                      && $0.confidence.isFinite
                      && (0...1).contains($0.confidence)
                      && Self.validatedLabel($0.boundary, maxLength: 120)
                      && Self.validatedLabel($0.negativeRegion, maxLength: 48)
                      && Self.validatedLabel($0.positiveRegion, maxLength: 48)
              })
        else {
            throw FlatteningError.invalidMesh("the anatomical cut plan or source mesh is invalid")
        }

        let sourceArea = try surfaceArea(positions: positions, triangles: triangles)
        var meshes = [Mesh(positions: positions, triangles: triangles, sourceVertices: Array(positions.indices))]
        var planeLocations: [(cut: AnatomicalCut, coordinate: Double, range: Double)] = []
        for cut in cuts {
            let values = positions.map { cut.axis.coordinate(of: $0) }
            guard let lower = values.min(), let upper = values.max(), upper > lower else {
                throw FlatteningError.invalidMesh("the mesh has no extent along the proposed \(cut.axis.rawValue)-axis cut")
            }
            let planeCoordinate = lower + (upper - lower) * cut.normalizedPosition
            planeLocations.append((cut, planeCoordinate, upper - lower))
            var next: [Mesh] = []
            var dividedAtThisPlane = false

            for mesh in meshes {
                let (positive, negative) = try clip(mesh, plane: CutPlane(axis: cut.axis, coordinate: planeCoordinate))
                if positive != nil && negative != nil {
                    dividedAtThisPlane = true
                }
                for side in [positive, negative].compactMap({ $0 }) {
                    let patches = try SurfaceCutter.components(
                        of: .whole(positions: side.positions, triangles: side.triangles),
                        cutting: []
                    )
                    next.append(contentsOf: patches.map {
                        Mesh(
                            positions: $0.positions,
                            triangles: $0.triangles,
                            sourceVertices: $0.origin.map { side.sourceVertices[$0] }
                        )
                    })
                }
            }

            guard dividedAtThisPlane, next.count > meshes.count else {
                throw FlatteningError.invalidMesh(
                    "the proposed \(cut.boundary) cut does not divide the current mesh"
                )
            }
            meshes = next
        }

        let components = meshes.enumerated().map { index, mesh in
            let centroid = mesh.positions.reduce(Vec3.zero, +) / Double(mesh.positions.count)
            let nearestBoundary = planeLocations.min {
                normalizedDistance(from: centroid, to: $0.coordinate, axis: $0.cut.axis, range: $0.range)
                    < normalizedDistance(from: centroid, to: $1.coordinate, axis: $1.cut.axis, range: $1.range)
            }
            let label = nearestBoundary.map {
                $0.cut.axis.coordinate(of: centroid) < $0.coordinate
                    ? $0.cut.negativeRegion
                    : $0.cut.positiveRegion
            }
            return MeshComponent(
                id: index,
                positions: mesh.positions,
                triangles: mesh.triangles,
                sourceVertices: mesh.sourceVertices,
                anatomicalLabel: label
            )
        }
        guard components.count > 1,
              components.allSatisfy({ component in
                  component.triangleCount > 0
                      && component.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
                      && component.triangles.allSatisfy { $0 >= 0 && Int($0) < component.positions.count }
              })
        else {
            throw FlatteningError.invalidMesh("the proposed cuts did not produce valid independent mesh pieces")
        }

        let resultArea = components.reduce(0) { $0 + $1.surfaceArea }
        guard resultArea.isFinite,
              abs(resultArea / sourceArea - 1) <= 1e-8
        else {
            throw FlatteningError.invalidMesh("the anatomical cuts failed surface-area conservation")
        }

        // Clipping at a plane that grazes the surface can leave a few-triangle sliver; it cannot be sewn.
        let kept = components.filter {
            !($0.triangleCount <= Self.maximumFragmentTriangles && $0.surfaceArea < sourceArea * Self.fragmentAreaFraction)
        }
        guard kept.count > 1 else {
            throw FlatteningError.invalidMesh("the proposed cuts did not produce valid independent mesh pieces")
        }
        return kept.enumerated().map { index, component in
            MeshComponent(
                id: index,
                positions: component.positions,
                triangles: component.triangles,
                sourceVertices: component.sourceVertices,
                anatomicalLabel: component.anatomicalLabel
            )
        }
    }

    private static func clip(
        _ mesh: Mesh,
        plane: CutPlane
    ) throws -> (positive: Mesh?, negative: Mesh?) {
        let scale = mesh.positions.map { simd_length($0) }.max() ?? 1
        let epsilon = max(scale * 1e-12, 1e-14)
        var positive = Builder()
        var negative = Builder()
        var positiveArea = 0.0
        var negativeArea = 0.0

        for offset in stride(from: 0, to: mesh.triangles.count, by: 3) {
            let indices = (0..<3).map { Int(mesh.triangles[offset + $0]) }
            let vertices = indices.map { ClippedVertex(key: .source($0), point: mesh.positions[$0]) }
            let distances = vertices.map { plane.signedDistance(to: $0.point) }
            let onPlane = distances.allSatisfy { abs($0) <= epsilon }
            let positivePolygon: [ClippedVertex]
            let negativePolygon: [ClippedVertex]
            if onPlane {
                positivePolygon = vertices
                negativePolygon = []
            } else {
                positivePolygon = try clippedPolygon(
                    vertices,
                    distances: distances,
                    keepPositive: true,
                    epsilon: epsilon,
                    plane: plane
                )
                negativePolygon = try clippedPolygon(
                    vertices,
                    distances: distances,
                    keepPositive: false,
                    epsilon: epsilon,
                    plane: plane
                )
            }
            positiveArea += try positive.append(positivePolygon, sourceVertices: mesh.sourceVertices)
            negativeArea += try negative.append(negativePolygon, sourceVertices: mesh.sourceVertices)
        }

        guard positiveArea.isFinite, negativeArea.isFinite else {
            throw FlatteningError.invalidMesh("a proposed plane produced non-finite geometry")
        }
        return (
            positiveArea > epsilon * epsilon ? positive.mesh(sourceVertices: positive.sourceVertices) : nil,
            negativeArea > epsilon * epsilon ? negative.mesh(sourceVertices: negative.sourceVertices) : nil
        )
    }

    private static func clippedPolygon(
        _ vertices: [ClippedVertex],
        distances: [Double],
        keepPositive: Bool,
        epsilon: Double,
        plane: CutPlane
    ) throws -> [ClippedVertex] {
        var output: [ClippedVertex] = []
        for index in 0..<vertices.count {
            let nextIndex = (index + 1) % vertices.count
            let current = vertices[index]
            let next = vertices[nextIndex]
            let currentDistance = abs(distances[index]) <= epsilon ? 0 : distances[index]
            let nextDistance = abs(distances[nextIndex]) <= epsilon ? 0 : distances[nextIndex]
            let currentInside = keepPositive ? currentDistance >= 0 : currentDistance <= 0
            let nextInside = keepPositive ? nextDistance >= 0 : nextDistance <= 0

            if currentInside {
                output.append(current)
            }
            if (currentDistance < 0 && nextDistance > 0) || (currentDistance > 0 && nextDistance < 0) {
                let amount = currentDistance / (currentDistance - nextDistance)
                let point = current.point + (next.point - current.point) * amount
                guard point.x.isFinite, point.y.isFinite, point.z.isFinite,
                      abs(plane.signedDistance(to: point)) <= epsilon * 8
                else {
                    throw FlatteningError.invalidMesh("a proposed plane intersection is invalid")
                }
                guard case .source(let currentIndex) = current.key,
                      case .source(let nextIndex) = next.key
                else {
                    throw FlatteningError.invalidMesh("a cut intersection references an invalid source edge")
                }
                output.append(ClippedVertex(
                    key: .intersection(Edge(currentIndex, nextIndex)),
                    point: point
                ))
            } else if !currentInside && nextInside && nextDistance == 0 {
                output.append(next)
            }
        }
        return deduplicated(output)
    }

    private static func deduplicated(_ vertices: [ClippedVertex]) -> [ClippedVertex] {
        var result: [ClippedVertex] = []
        for vertex in vertices where result.last?.key != vertex.key {
            result.append(vertex)
        }
        if result.count > 1, result.first?.key == result.last?.key {
            result.removeLast()
        }
        return result
    }

    private static func surfaceArea(positions: [Vec3], triangles: [Int32]) throws -> Double {
        var total = 0.0
        for offset in stride(from: 0, to: triangles.count, by: 3) {
            let a = positions[Int(triangles[offset])]
            let b = positions[Int(triangles[offset + 1])]
            let c = positions[Int(triangles[offset + 2])]
            let area = 0.5 * vlength(vcross(b - a, c - a))
            guard area.isFinite, area > 0 else { throw FlatteningError.degenerateTriangle }
            total += area
        }
        guard total.isFinite, total > 0 else {
            throw FlatteningError.invalidMesh("the source surface area is not finite and positive")
        }
        return total
    }

    private static func normalizedDistance(from point: Vec3, to plane: Double, axis: AnatomicalAxis, range: Double) -> Double {
        abs(axis.coordinate(of: point) - plane) / range
    }

    private static func validatedLabel(_ value: String, maxLength: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.count <= maxLength
            && trimmed.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private struct Builder {
        private(set) var positions: [Vec3] = []
        private(set) var triangles: [Int32] = []
        private(set) var sourceVertices: [Int] = []
        private var indices: [VertexKey: Int32] = [:]

        func mesh(sourceVertices: [Int]) -> Mesh? {
            guard !triangles.isEmpty else { return nil }
            return Mesh(positions: positions, triangles: triangles, sourceVertices: sourceVertices)
        }

        mutating func append(_ polygon: [ClippedVertex], sourceVertices: [Int]) throws -> Double {
            guard polygon.count >= 3 else { return 0 }
            var localIndices: [Int32] = []
            localIndices.reserveCapacity(polygon.count)
            for vertex in polygon {
                if let existing = indices[vertex.key] {
                    localIndices.append(existing)
                } else {
                    guard positions.count < Int(Int32.max) else {
                        throw FlatteningError.invalidMesh("the cut mesh exceeds the supported vertex count")
                    }
                    let index = Int32(positions.count)
                    positions.append(vertex.point)
                    if case .source(let sourceIndex) = vertex.key {
                        self.sourceVertices.append(sourceVertices[sourceIndex])
                    } else {
                        self.sourceVertices.append(-1)
                    }
                    indices[vertex.key] = index
                    localIndices.append(index)
                }
            }

            var polygonArea = 0.0
            for index in 1..<(localIndices.count - 1) {
                let a = positions[Int(localIndices[0])]
                let b = positions[Int(localIndices[index])]
                let c = positions[Int(localIndices[index + 1])]
                let triangleArea = 0.5 * vlength(vcross(b - a, c - a))
                guard triangleArea.isFinite else {
                    throw FlatteningError.invalidMesh("a clipped triangle has non-finite area")
                }
                guard triangleArea > Double.leastNonzeroMagnitude else { continue }
                triangles.append(contentsOf: [localIndices[0], localIndices[index], localIndices[index + 1]])
                polygonArea += triangleArea
            }
            return polygonArea
        }
    }
}

/// A place where a body part is sewn to the rest of the plush: a position on the mesh and the
/// direction of the limb through it. The cut is the plane through `position` perpendicular to `direction`.
struct AnatomicalJoint: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var position: Vec3
    var direction: Vec3
    /// Names for the pieces on the side `direction` points to and the opposite side.
    /// An empty label leaves the piece's existing name unchanged.
    var positiveLabel: String
    var negativeLabel: String
}

extension AnatomicalMeshSplitter {
    /// Cuts the mesh at each joint in order. A joint only cuts the piece nearest to it, so a limb joint
    /// cannot slice a different body part that happens to straddle the same plane.
    static func split(positions: [Vec3], triangles: [Int32], joints: [AnatomicalJoint]) throws -> [MeshComponent] {
        guard positions.count >= 3, triangles.count >= 3, triangles.count.isMultiple(of: 3),
              positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              triangles.allSatisfy({ $0 >= 0 && Int($0) < positions.count }),
              !joints.isEmpty, joints.count <= 16
        else {
            throw FlatteningError.invalidMesh("the joint list or source mesh is invalid")
        }
        let sourceArea = try surfaceArea(positions: positions, triangles: triangles)
        var meshes = [Mesh(positions: positions, triangles: triangles, sourceVertices: Array(positions.indices))]
        var labels: [String?] = [nil]

        for joint in joints {
            guard validatedLabel(joint.name, maxLength: 120),
                  joint.positiveLabel.count <= 48, joint.negativeLabel.count <= 48,
                  let plane = CutPlane(through: joint.position, normal: joint.direction)
            else {
                throw FlatteningError.invalidMesh("joint \"\(joint.name)\" is invalid")
            }
            let target = meshes.indices.min {
                nearestDistance(of: meshes[$0], to: joint.position) < nearestDistance(of: meshes[$1], to: joint.position)
            } ?? 0
            let (positive, negative) = try clip(meshes[target], plane: plane)
            guard let positive, let negative else {
                throw FlatteningError.invalidMesh("the \(joint.name) joint does not divide the piece it sits on")
            }
            var replacement: [(Mesh, String?)] = []
            for (side, label) in [(positive, joint.positiveLabel), (negative, joint.negativeLabel)] {
                let patches = try SurfaceCutter.components(of: .whole(positions: side.positions, triangles: side.triangles), cutting: [])
                for patch in patches {
                    replacement.append((
                        Mesh(positions: patch.positions, triangles: patch.triangles, sourceVertices: patch.origin.map { side.sourceVertices[$0] }),
                        label.isEmpty ? labels[target] : label
                    ))
                }
            }
            meshes.remove(at: target)
            labels.remove(at: target)
            for (offset, item) in replacement.enumerated() {
                meshes.insert(item.0, at: target + offset)
                labels.insert(item.1, at: target + offset)
            }
        }

        let components = meshes.enumerated().map { index, mesh in
            MeshComponent(id: index, positions: mesh.positions, triangles: mesh.triangles, sourceVertices: mesh.sourceVertices, anatomicalLabel: labels[index])
        }
        let resultArea = components.reduce(0) { $0 + $1.surfaceArea }
        guard components.count > 1, resultArea.isFinite, abs(resultArea / sourceArea - 1) <= 1e-8 else {
            throw FlatteningError.invalidMesh("the joint cuts failed surface-area conservation")
        }
        let kept = components.filter {
            !($0.triangleCount <= maximumFragmentTriangles && $0.surfaceArea < sourceArea * fragmentAreaFraction)
        }
        guard kept.count > 1 else {
            throw FlatteningError.invalidMesh("the joint cuts did not produce separate pieces")
        }
        return kept.enumerated().map { index, component in
            MeshComponent(id: index, positions: component.positions, triangles: component.triangles, sourceVertices: component.sourceVertices, anatomicalLabel: component.anatomicalLabel)
        }
    }

    private static func nearestDistance(of mesh: Mesh, to point: Vec3) -> Double {
        mesh.positions.reduce(Double.infinity) { min($0, vlength($1 - point)) }
    }
}

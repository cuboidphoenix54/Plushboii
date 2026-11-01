import Foundation

struct MeshComponent: Sendable, Equatable, Identifiable {
    let id: Int
    let positions: [Vec3]
    let triangles: [Int32]
    let sourceVertices: [Int]
    var anatomicalLabel: String? = nil

    var triangleCount: Int { triangles.count / 3 }

    var surfaceArea: Double {
        stride(from: 0, to: triangles.count, by: 3).reduce(0) { total, corner in
            let a = positions[Int(triangles[corner])]
            let b = positions[Int(triangles[corner + 1])]
            let c = positions[Int(triangles[corner + 2])]
            return total + 0.5 * vlength(vcross(b - a, c - a))
        }
    }
}

enum MeshComponentSplitter {
    static func split(
        positions: [Vec3],
        triangles: [Int32],
        seams: [[Int]]
    ) throws -> [MeshComponent] {
        guard positions.count >= 3, triangles.count >= 3, triangles.count.isMultiple(of: 3),
              positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              triangles.allSatisfy({ $0 >= 0 && Int($0) < positions.count })
        else {
            throw FlatteningError.invalidMesh("the mesh contains invalid vertices or triangles")
        }

        var cuts = Set<UInt64>()
        for seam in seams {
            guard seam.allSatisfy(positions.indices.contains) else {
                throw FlatteningError.invalidMesh("a split seam references a vertex outside the mesh")
            }
            for (a, b) in zip(seam, seam.dropFirst()) where a != b {
                cuts.insert(SurfaceCutter.edgeKey(Int32(a), Int32(b)))
            }
        }

        let patches = try SurfaceCutter.components(
            of: .whole(positions: positions, triangles: triangles),
            cutting: cuts
        )
        guard patches.count > 1 else {
            throw FlatteningError.invalidMesh("the selected seam paths do not divide the mesh into separate pieces")
        }

        let components = patches.enumerated().map { index, patch in
            return MeshComponent(
                id: index,
                positions: patch.positions,
                triangles: patch.triangles,
                sourceVertices: patch.origin
            )
        }
        guard components.allSatisfy({ component in
            component.positions.count >= 3
                && component.sourceVertices.count == component.positions.count
                && component.triangleCount > 0
                && component.triangles.allSatisfy {
                    $0 >= 0 && Int($0) < component.positions.count
                }
        }) else {
            throw FlatteningError.invalidMesh("a split piece contains invalid geometry")
        }
        return components
    }
}

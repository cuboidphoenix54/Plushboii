import Foundation
import simd

/// A regular grid of scalar samples. Index = x + n * (y + n * z); sample (0,0,0) sits at `origin`.
struct ScalarField: Sendable {
    let resolution: Int
    let values: [Float]
    let origin: SIMD3<Double>
    let spacing: Double

    init(resolution: Int, values: [Float], origin: SIMD3<Double>, spacing: Double) throws {
        guard resolution >= 2, resolution <= 512, spacing.isFinite, spacing > 0,
              values.count == resolution * resolution * resolution,
              origin.x.isFinite, origin.y.isFinite, origin.z.isFinite
        else { throw MeshIngestionError.invalidMesh("the scalar field has an invalid size or spacing") }
        self.resolution = resolution
        self.values = values
        self.origin = origin
        self.spacing = spacing
    }
}

/// Isosurface extraction by marching tetrahedra over the Kuhn 6-tetrahedron subdivision of every grid cube.
/// Samples with `value >= isoLevel` are inside. Chosen over the 256-case cube tables because its 16 cases are
/// derived rather than transcribed, it has no ambiguous faces, and the subdivision is face-consistent, so the
/// output is a closed, consistently oriented, edge-welded manifold wherever the surface does not touch the grid border.
enum MarchingTetrahedra {
    /// Corner `i` of a cube is at (i & 1, (i >> 1) & 1, (i >> 2) & 1); every tetrahedron shares the 0–7 diagonal.
    private static let tetrahedra: [(Int, Int, Int, Int)] = [
        (0, 1, 3, 7), (0, 1, 5, 7), (0, 2, 3, 7), (0, 2, 6, 7), (0, 4, 5, 7), (0, 4, 6, 7),
    ]
    private static let edgeEpsilon = 0.001

    /// Triangles are wound counter-clockwise when viewed from outside (towards falling field values).
    static func extract(_ field: ScalarField, isoLevel: Float = 0) throws -> ImportedMesh {
        guard isoLevel.isFinite, field.values.allSatisfy(\.isFinite) else {
            throw MeshIngestionError.invalidMesh("the scalar field contains a non-finite value")
        }
        let n = field.resolution
        let plane = n * n
        let total = UInt64(n * plane)

        var vertices = [MeshVertex]()
        var triangles = [MeshTriangle]()
        var edgeVertices = [UInt64: Int]()

        func position(_ index: Int) -> SIMD3<Double> {
            field.origin + SIMD3<Double>(Double(index % n), Double((index / n) % n), Double(index / plane)) * field.spacing
        }

        func edgeVertex(_ a: Int, _ b: Int) throws -> Int {
            let (lo, hi) = a < b ? (a, b) : (b, a)
            let key = UInt64(lo) * total + UInt64(hi)
            if let existing = edgeVertices[key] { return existing }
            let vLo = Double(field.values[lo]), vHi = Double(field.values[hi])
            let t = min(max((Double(isoLevel) - vLo) / (vHi - vLo), edgeEpsilon), 1 - edgeEpsilon)
            let p = position(lo) + (position(hi) - position(lo)) * t
            guard vertices.count < MeshSchemaEnforcer.maximumVertices else {
                throw MeshIngestionError.invalidMesh("the extracted surface exceeds the vertex safety limit")
            }
            vertices.append(MeshVertex(x: p.x, y: p.y, z: p.z))
            edgeVertices[key] = vertices.count - 1
            return vertices.count - 1
        }

        func emit(_ a: Int, _ b: Int, _ c: Int, insidePoint: SIMD3<Double>) {
            let pa = vertices[a], pb = vertices[b], pc = vertices[c]
            let va = SIMD3<Double>(pa.x, pa.y, pa.z), vb = SIMD3<Double>(pb.x, pb.y, pb.z), vc = SIMD3<Double>(pc.x, pc.y, pc.z)
            let normal = simd_cross(vb - va, vc - va)
            let centroid = (va + vb + vc) / 3
            triangles.append(simd_dot(normal, centroid - insidePoint) >= 0 ? MeshTriangle(a: a, b: b, c: c) : MeshTriangle(a: a, b: c, c: b))
        }

        for z in 0..<(n - 1) {
            try Task.checkCancellation()
            for y in 0..<(n - 1) {
                for x in 0..<(n - 1) {
                    let base = x + n * (y + n * z)
                    var corner = [Int](repeating: 0, count: 8)
                    for i in 0..<8 { corner[i] = base + (i & 1) + n * ((i >> 1) & 1) + plane * ((i >> 2) & 1) }
                    for tet in tetrahedra {
                        let ids = [corner[tet.0], corner[tet.1], corner[tet.2], corner[tet.3]]
                        let inside = ids.filter { field.values[$0] >= isoLevel }
                        let outside = ids.filter { field.values[$0] < isoLevel }
                        guard !inside.isEmpty, !outside.isEmpty else { continue }
                        let insidePoint = inside.map(position).reduce(.zero, +) / Double(inside.count)

                        if inside.count == 1 || outside.count == 1 {
                            let lone = inside.count == 1 ? inside[0] : outside[0]
                            let others = inside.count == 1 ? outside : inside
                            let e0 = try edgeVertex(lone, others[0])
                            let e1 = try edgeVertex(lone, others[1])
                            let e2 = try edgeVertex(lone, others[2])
                            emit(e0, e1, e2, insidePoint: insidePoint)
                        } else {
                            let ac = try edgeVertex(inside[0], outside[0]), ad = try edgeVertex(inside[0], outside[1])
                            let bd = try edgeVertex(inside[1], outside[1]), bc = try edgeVertex(inside[1], outside[0])
                            emit(ac, ad, bd, insidePoint: insidePoint)
                            emit(ac, bd, bc, insidePoint: insidePoint)
                        }
                        guard triangles.count <= MeshSchemaEnforcer.maximumTriangles else {
                            throw MeshIngestionError.invalidMesh("the extracted surface exceeds the triangle safety limit")
                        }
                    }
                }
            }
        }
        return try MeshSchemaEnforcer.validate(ImportedMesh(vertices: vertices, triangles: triangles))
    }
}

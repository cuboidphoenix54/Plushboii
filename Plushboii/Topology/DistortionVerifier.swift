import Foundation

/// Chain-of-Verification: recomputes every figure from the raw 3D positions and the final 2D
/// coordinates, independently of the solver that produced them.
enum DistortionVerifier {
    struct TriangleAreas {
        let area3D: [Double]
        let signedArea2D: [Double]
    }

    static func triangleAreas(positions: [Vec3], triangles: [Int32], uv: [Vec2]) -> TriangleAreas {
        let count = triangles.count / 3
        var area3D = [Double](repeating: 0, count: count)
        var area2D = [Double](repeating: 0, count: count)
        for t in 0..<count {
            let a = Int(triangles[t * 3]), b = Int(triangles[t * 3 + 1]), c = Int(triangles[t * 3 + 2])
            area3D[t] = 0.5 * vlength(vcross(positions[b] - positions[a], positions[c] - positions[a]))
            let u = uv[b] - uv[a], v = uv[c] - uv[a]
            area2D[t] = 0.5 * (u.x * v.y - u.y * v.x)
        }
        return TriangleAreas(area3D: area3D, signedArea2D: area2D)
    }

    static func verify(
        positions: [Vec3],
        triangles: [Int32],
        uv: [Vec2],
        areaFactor: Double,
        tolerance: Double,
        requireLocalAccuracy: Bool
    ) -> DistortionReport {
        let areas = triangleAreas(positions: positions, triangles: triangles, uv: uv)
        let total3D = DenseKernels.sum(areas.area3D)
        let magnitude2D = areas.signedArea2D.map { abs($0) }
        let total2D = DenseKernels.sum(magnitude2D)
        let expected = total3D * areaFactor
        let delta = expected > 0 ? abs(total2D - expected) / expected : .infinity

        var flipped = 0
        var weighted = [Double](repeating: 0, count: areas.area3D.count)
        var maximum = 0.0
        for t in areas.area3D.indices {
            if areas.signedArea2D[t] <= 0 { flipped += 1 }
            let reference = areas.area3D[t] * areaFactor
            let local = reference > 0 ? abs(magnitude2D[t] / reference - 1) : .infinity
            weighted[t] = local * areas.area3D[t]
            maximum = max(maximum, local)
        }
        let mean = total3D > 0 ? DenseKernels.sum(weighted) / total3D : .infinity

        let passed = delta.isFinite && delta <= tolerance
            && flipped == 0
            && (!requireLocalAccuracy || mean <= tolerance)
        return DistortionReport(
            area3D: total3D,
            area2D: total2D,
            expectedArea2D: expected,
            areaDelta: delta,
            tolerance: tolerance,
            meanLocalDistortion: mean,
            maxLocalDistortion: maximum,
            flippedTriangles: flipped,
            passed: passed
        )
    }
}

import Foundation

enum AreaPreservingUVRefiner {
    private struct Evaluation {
        let energy: Double
        let gradientX: [Double]
        let gradientY: [Double]
        let signedAreas: [Double]
    }

    static func refine(
        patch: SurfacePatch,
        boundaryLoop: [Int],
        initialUV: [Vec2]
    ) throws -> [Vec2] {
        guard initialUV.count == patch.positions.count,
              initialUV.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw FlatteningError.invalidMesh("the UV initialization is invalid")
        }

        let boundary = Set(boundaryLoop)
        let areas3D = DistortionVerifier.triangleAreas(
            positions: patch.positions,
            triangles: patch.triangles,
            uv: initialUV
        ).area3D
        guard areas3D.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw FlatteningError.degenerateTriangle
        }

        var uv = initialUV
        var evaluation = evaluate(patch: patch, uv: uv, areas3D: areas3D)
        guard evaluation.energy.isFinite else {
            return initialUV
        }
        var bestValidUV: [Vec2]? = evaluation.signedAreas.allSatisfy({ $0 > 0 }) ? uv : nil
        var bestValidEnergy = bestValidUV == nil ? .infinity : evaluation.energy

        for _ in 0..<200 {
            let maxGradient = zip(evaluation.gradientX, evaluation.gradientY)
                .map { hypot($0, $1) }
                .max() ?? 0
            guard maxGradient.isFinite, maxGradient > 1e-12 else { break }

            var step = 0.1
            var accepted: (uv: [Vec2], evaluation: Evaluation)?
            for _ in 0..<20 {
                var candidate = uv
                for vertex in candidate.indices where !boundary.contains(vertex) {
                    candidate[vertex] = Vec2(
                        candidate[vertex].x - step * evaluation.gradientX[vertex],
                        candidate[vertex].y - step * evaluation.gradientY[vertex]
                    )
                }
                let next = evaluate(patch: patch, uv: candidate, areas3D: areas3D)
                let isValid = next.signedAreas.indices.allSatisfy {
                    next.signedAreas[$0] > max(areas3D[$0] * 1e-10, 1e-15)
                }
                if next.energy.isFinite, next.energy < evaluation.energy,
                   (!evaluation.signedAreas.allSatisfy({ $0 > 0 }) || isValid) {
                    accepted = (candidate, next)
                    if isValid, next.energy < bestValidEnergy {
                        bestValidUV = candidate
                        bestValidEnergy = next.energy
                    }
                    break
                }
                step *= 0.5
            }
            guard let accepted else { break }
            uv = accepted.uv
            evaluation = accepted.evaluation
        }
        return bestValidUV ?? initialUV
    }

    private static func evaluate(
        patch: SurfacePatch,
        uv: [Vec2],
        areas3D: [Double]
    ) -> Evaluation {
        var energy = 0.0
        var gradientX = [Double](repeating: 0, count: uv.count)
        var gradientY = [Double](repeating: 0, count: uv.count)
        var signedAreas = [Double](repeating: 0, count: patch.triangleCount)

        for triangle in 0..<patch.triangleCount {
            let a = Int(patch.triangles[triangle * 3])
            let b = Int(patch.triangles[triangle * 3 + 1])
            let c = Int(patch.triangles[triangle * 3 + 2])
            let ua = uv[a]
            let ub = uv[b]
            let uc = uv[c]
            let ab = ub - ua
            let ac = uc - ua
            let area2D = 0.5 * (ab.x * ac.y - ab.y * ac.x)
            signedAreas[triangle] = area2D
            let error = area2D / areas3D[triangle] - 1
            energy += areas3D[triangle] * error * error
            let scale = 2 * error

            gradientX[a] += scale * 0.5 * (ub.y - uc.y)
            gradientY[a] += scale * 0.5 * (uc.x - ub.x)
            gradientX[b] += scale * 0.5 * (uc.y - ua.y)
            gradientY[b] += scale * 0.5 * (ua.x - uc.x)
            gradientX[c] += scale * 0.5 * (ua.y - ub.y)
            gradientY[c] += scale * 0.5 * (ub.x - ua.x)
        }
        return Evaluation(
            energy: energy,
            gradientX: gradientX,
            gradientY: gradientY,
            signedAreas: signedAreas
        )
    }
}

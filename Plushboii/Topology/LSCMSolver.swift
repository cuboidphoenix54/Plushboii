import Foundation

struct LSCMSolution: Sendable {
    /// Island coordinates already scaled to best match 3D edge lengths.
    let uv: [Vec2]
    let iterations: Int
    let relativeResidual: Double
}

/// Weighted Least Squares Conformal Maps (Lévy et al. 2002) with two pinned boundary vertices.
/// The over-determined system is solved with Jacobi-scaled CGLS; vector updates use vDSP.
enum LSCMSolver {
    static let tolerance = 1e-11

    static func solve(patch: SurfacePatch, boundaryLoop: [Int32], weights: [Double]) throws -> LSCMSolution {
        let vertexCount = patch.positions.count
        let triangleCount = patch.triangleCount
        precondition(weights.count == triangleCount)
        guard vertexCount >= 3, boundaryLoop.count >= 3 else { throw FlatteningError.degenerateTriangle }

        let (pinA, pinB) = choosePins(patch: patch, boundary: boundaryLoop)
        let pinDistance = vlength(patch.positions[pinB] - patch.positions[pinA])
        guard pinDistance > 0 else { throw FlatteningError.degenerateTriangle }

        var freeIndex = [Int32](repeating: -1, count: vertexCount)
        var freeCount = 0
        for v in 0..<vertexCount where v != pinA && v != pinB {
            freeIndex[v] = Int32(freeCount)
            freeCount += 1
        }
        let columns = freeCount * 2

        // Each triangle contributes the real and imaginary rows of sum_j W_j (U_j + i V_j) = 0.
        var rowStart: [Int] = [0]
        var columnIndex: [Int32] = []
        var values: [Double] = []
        var rhs = [Double](repeating: 0, count: triangleCount * 2)
        rowStart.reserveCapacity(triangleCount * 2 + 1)
        columnIndex.reserveCapacity(triangleCount * 12)
        values.reserveCapacity(triangleCount * 12)

        for t in 0..<triangleCount {
            let i0 = Int(patch.triangles[t * 3]), i1 = Int(patch.triangles[t * 3 + 1]), i2 = Int(patch.triangles[t * 3 + 2])
            let p0 = patch.positions[i0]
            let e1 = patch.positions[i1] - p0
            let e2 = patch.positions[i2] - p0
            let x2 = vlength(e1)
            let normal = vcross(e1, e2)
            let normalLength = vlength(normal)
            let scale = max(x2, vlength(e2))
            guard x2 > 0, normalLength > 1e-12 * scale * scale, weights[t] > 0, weights[t].isFinite else {
                throw FlatteningError.degenerateTriangle
            }
            let xAxis = e1 / x2
            let yAxis = vcross(normal / normalLength, xAxis)
            let x3 = vdot(e2, xAxis)
            let y3 = vdot(e2, yAxis)
            let doubledArea = x2 * y3
            let factor = (weights[t] / doubledArea).squareRoot()

            let w = [
                (a: (x3 - x2) * factor, b: y3 * factor),
                (a: -x3 * factor, b: -y3 * factor),
                (a: x2 * factor, b: 0.0)
            ]
            let vertices = [i0, i1, i2]

            var realRow: [(Int32, Double)] = []
            var imagRow: [(Int32, Double)] = []
            var realRHS = 0.0, imagRHS = 0.0
            for k in 0..<3 {
                let vertex = vertices[k]
                let (a, b) = (w[k].a, w[k].b)
                if vertex == pinA {
                    continue
                } else if vertex == pinB {
                    realRHS -= a * pinDistance
                    imagRHS -= b * pinDistance
                } else {
                    let u = freeIndex[vertex], v = Int32(freeCount) + freeIndex[vertex]
                    realRow.append((u, a)); realRow.append((v, -b))
                    imagRow.append((u, b)); imagRow.append((v, a))
                }
            }
            for entry in realRow { columnIndex.append(entry.0); values.append(entry.1) }
            rowStart.append(values.count)
            for entry in imagRow { columnIndex.append(entry.0); values.append(entry.1) }
            rowStart.append(values.count)
            rhs[t * 2] = realRHS
            rhs[t * 2 + 1] = imagRHS
        }

        var columnNorm = [Double](repeating: 0, count: columns)
        for (index, column) in columnIndex.enumerated() {
            columnNorm[Int(column)] += values[index] * values[index]
        }
        var columnScale = [Double](repeating: 1, count: columns)
        for c in 0..<columns {
            guard columnNorm[c] > 0 else { throw FlatteningError.degenerateTriangle }
            columnScale[c] = 1 / columnNorm[c].squareRoot()
        }
        for (index, column) in columnIndex.enumerated() {
            values[index] *= columnScale[Int(column)]
        }

        let matrix = CSRMatrix(rowStart: rowStart, columnIndex: columnIndex, values: values, columns: columns)
        let (scaledSolution, iterations, residual) = try cgls(matrix, rhs: rhs)

        var uv = [Vec2](repeating: .zero, count: vertexCount)
        uv[pinB] = Vec2(pinDistance, 0)
        for v in 0..<vertexCount where freeIndex[v] >= 0 {
            let k = Int(freeIndex[v])
            uv[v] = Vec2(
                scaledSolution[k] * columnScale[k],
                scaledSolution[freeCount + k] * columnScale[freeCount + k]
            )
        }
        return LSCMSolution(uv: fitScale(uv, to: patch), iterations: iterations, relativeResidual: residual)
    }

    /// Two boundary vertices that are far apart fix the similarity ambiguity of the conformal map.
    private static func choosePins(patch: SurfacePatch, boundary: [Int32]) -> (Int, Int) {
        let ordered = boundary.map(Int.init).sorted()
        let centroid = ordered.reduce(Vec3.zero) { $0 + patch.positions[$1] } / Double(ordered.count)
        var first = ordered[0]
        var best = -1.0
        for v in ordered {
            let distance = vlength(patch.positions[v] - centroid)
            if distance > best { best = distance; first = v }
        }
        var second = ordered[0] == first && ordered.count > 1 ? ordered[1] : ordered[0]
        best = -1.0
        for v in ordered where v != first {
            let distance = vlength(patch.positions[v] - patch.positions[first])
            if distance > best { best = distance; second = v }
        }
        return (first, second)
    }

    /// Least-squares uniform scale so 2D edge lengths match the 3D edge lengths.
    static func fitScale(_ uv: [Vec2], to patch: SurfacePatch) -> [Vec2] {
        var lengths3D: [Double] = []
        var lengths2D: [Double] = []
        lengths3D.reserveCapacity(patch.triangles.count)
        lengths2D.reserveCapacity(patch.triangles.count)
        for t in 0..<patch.triangleCount {
            for k in 0..<3 {
                let a = Int(patch.triangles[t * 3 + k]), b = Int(patch.triangles[t * 3 + (k + 1) % 3])
                lengths3D.append(vlength(patch.positions[a] - patch.positions[b]))
                lengths2D.append(vlength(uv[a] - uv[b]))
            }
        }
        let denominator = DenseKernels.dot(lengths2D, lengths2D)
        guard denominator > 0 else { return uv }
        let scale = DenseKernels.dot(lengths3D, lengths2D) / denominator
        return uv.map { $0 * scale }
    }

    private static func cgls(_ a: CSRMatrix, rhs: [Double]) throws -> ([Double], Int, Double) {
        var x = [Double](repeating: 0, count: a.columns)
        var r = rhs
        var s = a.transposeMultiply(r)
        var p = s
        var gamma = DenseKernels.dot(s, s)
        let initial = gamma.squareRoot()
        guard initial > 0 else { return (x, 0, 0) }

        let maximumIterations = min(max(500, 4 * a.columns), 200_000)
        var iteration = 0
        var relative = 1.0
        while iteration < maximumIterations {
            let q = a.multiply(p)
            let qq = DenseKernels.dot(q, q)
            guard qq > 0 else { break }
            let alpha = gamma / qq
            DenseKernels.axpy(alpha, p, into: &x)
            DenseKernels.axpy(-alpha, q, into: &r)
            s = a.transposeMultiply(r)
            let updated = DenseKernels.dot(s, s)
            iteration += 1
            relative = updated.squareRoot() / initial
            if relative <= tolerance { break }
            DenseKernels.scaledAdd(s, beta: updated / gamma, into: &p)
            gamma = updated
        }
        guard relative <= 1e-8 else { throw FlatteningError.solverDidNotConverge(relativeResidual: relative) }
        return (x, iteration, relative)
    }
}

struct CSRMatrix: Sendable {
    let rowStart: [Int]
    let columnIndex: [Int32]
    let values: [Double]
    let columns: Int

    var rows: Int { rowStart.count - 1 }

    func multiply(_ x: [Double]) -> [Double] {
        var result = [Double](repeating: 0, count: rows)
        for row in 0..<rows {
            var total = 0.0
            for k in rowStart[row]..<rowStart[row + 1] {
                total += values[k] * x[Int(columnIndex[k])]
            }
            result[row] = total
        }
        return result
    }

    func transposeMultiply(_ y: [Double]) -> [Double] {
        var result = [Double](repeating: 0, count: columns)
        for row in 0..<rows {
            let weight = y[row]
            for k in rowStart[row]..<rowStart[row + 1] {
                result[Int(columnIndex[k])] += values[k] * weight
            }
        }
        return result
    }
}

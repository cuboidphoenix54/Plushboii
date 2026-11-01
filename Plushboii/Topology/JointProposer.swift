import Foundation

/// Finds likely joints from geometry: narrow cross-sections between two bulky regions (a neck, a limb root).
/// It recurses, so cutting a neck first lets the next search see the body without the head dominating.
enum JointProposer {
    static let sliceCount = 48
    static let minimumProminence = 0.35
    static let minimumSideShare = 0.08
    static let edgeMargin = 0.06

    private struct Candidate {
        let axis: AnatomicalAxis
        let coordinate: Double
        let centroid: Vec3
        let prominence: Double
    }

    static func propose(positions: [Vec3], triangles: [Int32], maximumJoints: Int = 6) -> [AnatomicalJoint] {
        guard positions.count >= 3, triangles.count >= 3, maximumJoints > 0 else { return [] }
        var pieces = [(positions: positions, triangles: triangles)]
        var joints: [AnatomicalJoint] = []
        let totalArea = area(positions: positions, triangles: triangles)
        guard totalArea > 0 else { return [] }

        while joints.count < maximumJoints {
            var best: (index: Int, candidate: Candidate)?
            for (index, piece) in pieces.enumerated() where area(positions: piece.positions, triangles: piece.triangles) >= totalArea * 0.05 {
                for candidate in candidates(positions: piece.positions, triangles: piece.triangles)
                where best == nil || candidate.prominence > best!.candidate.prominence {
                    best = (index, candidate)
                }
            }
            guard let (index, candidate) = best else { break }
            let piece = pieces[index]
            let direction: Vec3 = switch candidate.axis {
            case .x: Vec3(1, 0, 0)
            case .y: Vec3(0, 1, 0)
            case .z: Vec3(0, 0, 1)
            }
            var joint = AnatomicalJoint(
                name: "Joint \(joints.count + 1)",
                position: candidate.centroid,
                direction: direction,
                positiveLabel: "",
                negativeLabel: ""
            )
            guard let halves = try? AnatomicalMeshSplitter.split(positions: piece.positions, triangles: piece.triangles, joints: [joint]),
                  halves.count >= 2
            else { break }
            // The smaller side beyond a joint is the appendage; the larger side keeps its name.
            let positiveArea = halves.filter { vdot(centroid($0), direction) > vdot(candidate.centroid, direction) }.reduce(0) { $0 + $1.surfaceArea }
            let negativeArea = halves.reduce(0) { $0 + $1.surfaceArea } - positiveArea
            if positiveArea < negativeArea { joint.positiveLabel = "\(joint.name) part" } else { joint.negativeLabel = "\(joint.name) part" }
            joints.append(joint)
            pieces.remove(at: index)
            pieces.append(contentsOf: halves.map { ($0.positions, $0.triangles) })
        }
        return joints
    }

    private static func candidates(positions: [Vec3], triangles: [Int32]) -> [Candidate] {
        var result: [Candidate] = []
        for axis in AnatomicalAxis.allCases {
            let values = positions.map { axis.coordinate(of: $0) }
            guard let lo = values.min(), let hi = values.max(), hi - lo > 1e-9 else { continue }
            let planes = (0..<sliceCount).map { lo + (hi - lo) * (Double($0) + 0.5) / Double(sliceCount) }
            var perimeter = [Double](repeating: 0, count: sliceCount)
            var weighted = [Vec3](repeating: .zero, count: sliceCount)
            for t in stride(from: 0, to: triangles.count, by: 3) {
                let p = (0..<3).map { positions[Int(triangles[t + $0])] }
                let c = p.map { axis.coordinate(of: $0) }
                guard let cLo = c.min(), let cHi = c.max() else { continue }
                let first = max(0, Int(((cLo - lo) / (hi - lo)) * Double(sliceCount) - 0.5))
                let last = min(sliceCount - 1, Int(((cHi - lo) / (hi - lo)) * Double(sliceCount) + 0.5))
                guard first <= last else { continue }
                for slice in first...last {
                    let level = planes[slice]
                    var points: [Vec3] = []
                    for k in 0..<3 {
                        let a = p[k], b = p[(k + 1) % 3], da = c[k] - level, db = c[(k + 1) % 3] - level
                        if (da < 0 && db > 0) || (da > 0 && db < 0) { points.append(a + (b - a) * (da / (da - db))) }
                    }
                    if points.count == 2 {
                        let length = vlength(points[1] - points[0])
                        perimeter[slice] += length
                        weighted[slice] += (points[0] + points[1]) * 0.5 * length
                    }
                }
            }
            let total = perimeter.reduce(0, +)
            guard total > 0 else { continue }
            let margin = Int((Double(sliceCount) * edgeMargin).rounded(.up))
            guard sliceCount > 2 * margin + 2 else { continue }
            for i in margin..<(sliceCount - margin) where perimeter[i] > 0 {
                guard perimeter[i] <= perimeter[i - 1], perimeter[i] <= perimeter[i + 1] else { continue }
                let leftMax = perimeter[0..<i].max() ?? 0
                let rightMax = perimeter[(i + 1)...].max() ?? 0
                let shoulder = min(leftMax, rightMax)
                guard shoulder > 0 else { continue }
                let prominence = 1 - perimeter[i] / shoulder
                let leftShare = perimeter[0..<i].reduce(0, +) / total
                let rightShare = perimeter[(i + 1)...].reduce(0, +) / total
                guard prominence >= minimumProminence, leftShare >= minimumSideShare, rightShare >= minimumSideShare else { continue }
                result.append(Candidate(axis: axis, coordinate: planes[i], centroid: weighted[i] / perimeter[i], prominence: prominence))
            }
        }
        return result
    }

    private static func centroid(_ component: MeshComponent) -> Vec3 {
        component.positions.reduce(Vec3.zero, +) / Double(component.positions.count)
    }

    private static func area(positions: [Vec3], triangles: [Int32]) -> Double {
        stride(from: 0, to: triangles.count, by: 3).reduce(0) { total, t in
            let a = positions[Int(triangles[t])], b = positions[Int(triangles[t + 1])], c = positions[Int(triangles[t + 2])]
            return total + 0.5 * vlength(vcross(b - a, c - a))
        }
    }
}

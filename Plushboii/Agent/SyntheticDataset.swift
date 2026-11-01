import Foundation

/// Generates labelled training examples for the anatomy advisor. Each creature is built from ellipsoid parts
/// (torso, head, wings, legs, tail) blended with a smooth union, so the true joint locations are known from
/// construction rather than guessed. Meshes get a random axis permutation/flip, as real imports do.
public enum SyntheticDataset {
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private struct Part {
        let name: String
        let center: Vec3
        let radii: Vec3

        func distance(_ p: Vec3) -> Double {
            let q = (p - center) / radii
            return (vlength(q) - 1) * min(radii.x, radii.y, radii.z)
        }
    }

    private struct Creature {
        let torso: Part
        /// Appendages in addition to the torso; each is joined to the torso.
        let appendages: [Part]
        var parts: [Part] { [torso] + appendages }

        func field(_ p: Vec3) -> Double {
            let smoothing = 0.25
            return parts.dropFirst().reduce(torso.distance(p)) { a, part in
                let b = part.distance(p)
                let h = max(smoothing - abs(a - b), 0) / smoothing
                return min(a, b) - h * h * smoothing / 4
            }
        }
    }

    private struct LabelCut: Codable {
        let axis: String
        let normalizedPosition: Double
        let boundary: String
        let negativeRegion: String
        let positiveRegion: String
        let confidence: Double
    }

    private struct LabelPlan: Codable {
        let summary: String
        let cuts: [LabelCut]
    }

    private struct Message: Codable {
        let role: String
        let content: String
        let images: [String]?
    }

    private struct Row: Codable {
        let messages: [Message]
    }

    public struct Summary: Sendable {
        public let written: Int
        public let skipped: Int
    }

    public static func generate(count: Int, seed: UInt64, outputDirectory: URL, resolution: Int = 56) throws -> Summary {
        guard count > 0, resolution >= 24, resolution <= 128 else {
            throw PlushAgentError.unreadable("count must be positive and resolution within 24...128")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var rng = SplitMix64(state: seed)
        var rows: [Data] = []
        var skipped = 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for index in 0..<count {
            let creature = makeCreature(&rng)
            guard let example = try? build(creature, rng: &rng, resolution: resolution) else { skipped += 1; continue }
            let name = String(format: "creature_%04d", index)
            let directory = outputDirectory.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let views = try AnatomyMeshViewRenderer.render(positions: example.positions, triangles: example.triangles)
            var imagePaths: [String] = []
            for (view, data) in zip(AnatomyMeshViewRenderer.View.allCases, views) {
                let file = "\(name)/\(view.rawValue).png"
                try data.write(to: outputDirectory.appendingPathComponent(file))
                imagePaths.append(file)
            }
            let label = String(decoding: try encoder.encode(example.plan), as: UTF8.self)
            let row = Row(messages: [
                Message(role: "user", content: OnDeviceSeamAdvisor.anatomyPrompt, images: imagePaths),
                Message(role: "assistant", content: label, images: nil),
            ])
            rows.append(try encoder.encode(row))
            try label.write(to: directory.appendingPathComponent("label.json"), atomically: true, encoding: .utf8)
        }

        // Hold out every tenth example for validation.
        let train = rows.enumerated().filter { $0.offset % 10 != 9 }.map(\.element)
        let valid = rows.enumerated().filter { $0.offset % 10 == 9 }.map(\.element)
        try write(lines: train, to: outputDirectory.appendingPathComponent("train.jsonl"))
        try write(lines: valid, to: outputDirectory.appendingPathComponent("valid.jsonl"))
        return Summary(written: rows.count, skipped: skipped)
    }

    private static func write(lines: [Data], to url: URL) throws {
        var data = Data()
        for line in lines { data.append(line); data.append(0x0A) }
        try data.write(to: url)
    }

    private static func uniform(_ range: ClosedRange<Double>, _ rng: inout SplitMix64) -> Double {
        Double.random(in: range, using: &rng)
    }

    private static func makeCreature(_ rng: inout SplitMix64) -> Creature {
        let rx = uniform(0.8...1.1, &rng), ry = uniform(0.9...1.2, &rng), rz = uniform(0.7...0.95, &rng)
        let torso = Part(name: "torso", center: .zero, radii: Vec3(rx, ry, rz))
        var parts: [Part] = []
        let head = uniform(0.5...0.75, &rng)
        parts.append(Part(name: "head", center: Vec3(0, ry + head * 0.75, 0), radii: Vec3(head, head * 0.95, head)))
        if Bool.random(using: &rng) {
            let span = uniform(0.45...0.65, &rng)
            for (side, sign) in [("left", 1.0), ("right", -1.0)] {
                parts.append(Part(name: "\(side) wing", center: Vec3(sign * (rx + span * 0.8), 0.2, -0.1), radii: Vec3(span, 0.35, 0.18)))
            }
        } else if Bool.random(using: &rng) {
            let reach = uniform(0.3...0.45, &rng)
            for (side, sign) in [("left", 1.0), ("right", -1.0)] {
                parts.append(Part(name: "\(side) arm", center: Vec3(sign * (rx + reach * 0.8), 0.1, 0.1), radii: Vec3(reach, 0.28, 0.28)))
            }
        }
        if Bool.random(using: &rng) {
            let leg = uniform(0.28...0.4, &rng)
            for (side, sign) in [("left", 1.0), ("right", -1.0)] {
                parts.append(Part(name: "\(side) leg", center: Vec3(sign * rx * 0.5, -ry - leg * 0.8, 0.1), radii: Vec3(leg, leg * 1.1, leg)))
            }
        }
        if Int.random(in: 0..<3, using: &rng) == 0 {
            let tail = uniform(0.22...0.32, &rng)
            parts.append(Part(name: "tail", center: Vec3(0, -0.3, -(rz + tail * 1.2)), radii: Vec3(tail, tail, tail * 1.4)))
        }
        return Creature(torso: torso, appendages: parts)
    }

    private static func build(
        _ creature: Creature,
        rng: inout SplitMix64,
        resolution n: Int
    ) throws -> (positions: [Vec3], triangles: [Int32], plan: LabelPlan) {
        let extent = 4.4
        let spacing = extent / Double(n - 1)
        let origin = Vec3(repeating: -extent / 2)
        var values = [Float](repeating: 0, count: n * n * n)
        for z in 0..<n { for y in 0..<n { for x in 0..<n {
            let p = origin + Vec3(Double(x), Double(y), Double(z)) * spacing
            values[x + n * (y + n * z)] = Float(-creature.field(p))
        } } }
        let field = try ScalarField(resolution: n, values: values, origin: origin, spacing: spacing)
        let mesh = try MarchingTetrahedra.extract(field)
        guard mesh.triangles.count > 200 else { throw PlushAgentError.unreadable("creature mesh too small") }
        guard OpenPieceSeams.boundaryLoops(triangles: mesh.topologyInput.triangles).isEmpty else {
            throw PlushAgentError.unreadable("creature mesh touches the grid border")
        }

        // Random signed axis permutation so the model is not always upright.
        var order = [0, 1, 2]; order.shuffle(using: &rng)
        let signs = (0..<3).map { _ in Bool.random(using: &rng) ? 1.0 : -1.0 }
        func transform(_ p: Vec3) -> Vec3 { Vec3(p[order[0]] * signs[0], p[order[1]] * signs[1], p[order[2]] * signs[2]) }
        let (rawPositions, triangles) = mesh.topologyInput
        var positions = rawPositions.map(transform)
        var flipped = false
        if signs[0] * signs[1] * signs[2] < 0 {
            // A reflection reverses winding; restore outward-facing triangles.
            flipped = true
        }
        var fixedTriangles = triangles
        if flipped { for t in stride(from: 0, to: fixedTriangles.count, by: 3) { fixedTriangles.swapAt(t + 1, t + 2) } }

        var lo = positions[0], hi = positions[0]
        for p in positions { lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)); hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)) }
        let axes = ["x", "y", "z"]

        var cuts: [LabelCut] = []
        for part in creature.appendages {
            // The joint is where the two parts' surfaces are equidistant on the segment between their centers.
            let a = creature.torso.center, b = part.center
            var low = 0.0, high = 1.0
            for _ in 0..<40 {
                let mid = (low + high) / 2
                let p = a + (b - a) * mid
                if creature.torso.distance(p) < part.distance(p) { low = mid } else { high = mid }
            }
            let joint = a + (b - a) * ((low + high) / 2)
            let direction = transform(b - a)
            guard let axis = (0..<3).max(by: { abs(direction[$0]) < abs(direction[$1]) }) else { continue }
            let span = hi[axis] - lo[axis]
            let position = (transform(joint)[axis] - lo[axis]) / span
            guard (0.1...0.9).contains(position) else { continue }
            let partIsPositive = direction[axis] > 0
            cuts.append(LabelCut(
                axis: axes[axis],
                normalizedPosition: (position * 1000).rounded() / 1000,
                boundary: "\(part.name) joint",
                negativeRegion: partIsPositive ? "torso" : part.name,
                positiveRegion: partIsPositive ? part.name : "torso",
                confidence: 0.9
            ))
        }
        guard !cuts.isEmpty else { throw PlushAgentError.unreadable("no usable joints") }
        let names = creature.appendages.map(\.name).joined(separator: ", ")
        let plan = LabelPlan(summary: "Torso with \(creature.appendages.count) joined parts: \(names). Cut at each joint.", cuts: cuts)
        positions = positions.map { $0 }
        return (positions, fixedTriangles, plan)
    }
}

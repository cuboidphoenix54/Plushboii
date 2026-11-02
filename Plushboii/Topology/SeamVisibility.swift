import Foundation

/// A box in normalized mesh bounds (0...1 per axis, order x, y, z) where seams would be conspicuous on the finished plush.
struct VisibleRegion: Codable, Equatable, Sendable {
    let name: String
    let min: [Double]
    let max: [Double]
    /// 1 = a seam here is as noticeable as it can be; 0 = hidden.
    let weight: Double

    func contains(_ normalized: [Double]) -> Bool {
        guard min.count == 3, max.count == 3, normalized.count == 3 else { return false }
        return (0..<3).allSatisfy { normalized[$0] >= min[$0] && normalized[$0] <= max[$0] }
    }
}

/// Where seams would show on the finished plush (faces, muzzles, eyes), from MLX anatomy labels and user corrections.
struct SeamVisibility: Codable, Equatable, Sendable {
    var regions: [VisibleRegion] = []
    private(set) var lower: [Double]?
    private(set) var upper: [Double]?

    static let none = SeamVisibility()
    static let conspicuousKeywords = ["face", "muzzle", "snout", "beak", "nose", "mouth", "eye", "cheek", "forehead"]
    static let weightInSeamScore = 0.6

    var isEmpty: Bool { regions.isEmpty }

    /// Fixes the normalization to the whole mesh, so a piece's positions can be judged against regions drawn on the whole.
    func bound(to positions: [Vec3]) -> SeamVisibility {
        guard let first = positions.first else { return self }
        var lo = first, hi = first
        for p in positions {
            lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
            hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
        }
        var copy = self
        copy.lower = [lo.x, lo.y, lo.z]
        copy.upper = [hi.x, hi.y, hi.z]
        return copy
    }

    /// Visibility weight at a point, the largest of the regions containing it.
    func weight(at point: Vec3) -> Double {
        guard let lower, let upper, !regions.isEmpty else { return 0 }
        let p = [point.x, point.y, point.z]
        let normalized = (0..<3).map { upper[$0] > lower[$0] ? (p[$0] - lower[$0]) / (upper[$0] - lower[$0]) : 0.5 }
        return regions.filter { $0.contains(normalized) }.map(\.weight).max() ?? 0
    }

    /// Length-weighted mean visibility along each seam path (edge midpoints), 0 when nothing is conspicuous.
    func penalty(of paths: [[Int]], positions: [Vec3]) -> Double {
        guard !regions.isEmpty else { return 0 }
        var total = 0.0, length = 0.0
        for path in paths {
            for (a, b) in zip(path, path.dropFirst()) where positions.indices.contains(a) && positions.indices.contains(b) {
                let edge = vlength(positions[b] - positions[a])
                total += weight(at: (positions[a] + positions[b]) * 0.5) * edge
                length += edge
            }
        }
        return length > 0 ? total / length : 0
    }

    /// Regions implied by cut labels: the side of a cut named as a face part is conspicuous.
    static func derived(from cuts: [AnatomicalCut]) -> [VisibleRegion] {
        func conspicuous(_ name: String) -> Bool { conspicuousKeywords.contains { name.lowercased().contains($0) } }
        var regions: [VisibleRegion] = []
        for cut in cuts {
            let axis = AnatomicalAxis.allCases.firstIndex(of: cut.axis) ?? 0
            for (name, negative) in [(cut.negativeRegion, true), (cut.positiveRegion, false)] where conspicuous(name) {
                var lo = [0.0, 0, 0], hi = [1.0, 1, 1]
                if negative { hi[axis] = cut.normalizedPosition } else { lo[axis] = cut.normalizedPosition }
                regions.append(VisibleRegion(name: name, min: lo, max: hi, weight: 1))
            }
        }
        return regions
    }
}

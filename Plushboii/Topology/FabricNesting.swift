import Foundation

enum NestingError: LocalizedError, Equatable {
    case invalidInput
    case pieceTooWide(id: Int, width: Double, fabricWidth: Double)

    var errorDescription: String? {
        switch self {
        case .invalidInput: "Nesting needs a positive fabric width and pieces with positive, finite sizes."
        case .pieceTooWide(let id, let width, let fabricWidth):
            String(format: "Piece %d is %.1f wide, which does not fit the %.1f wide fabric.", id, width, fabricWidth)
        }
    }
}

/// Lays cut pieces out on a fabric of fixed width to estimate yardage, using MaxRects bin packing with a
/// bottom-left rule (Jylänki 2010) over several piece orderings, keeping the shortest result.
///
/// Pieces are packed by their bounding boxes (cut line included), so the length is a safe upper bound, not a true
/// polygon nesting. Rotation by 90° is off by default because it turns the nap/grain; a piece may always be cut
/// as its mirror image or turned 180° without changing its bounding box.
enum FabricNesting {
    struct Piece: Sendable, Equatable {
        let id: Int
        let width: Double
        let height: Double
        /// Number of copies to cut, mirror copies included.
        var copies = 1
    }

    struct Placement: Sendable, Equatable {
        let id: Int
        let copy: Int
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let rotated: Bool
    }

    struct Layout: Sendable, Equatable {
        let placements: [Placement]
        let fabricWidth: Double
        /// Fabric length consumed along the selvedge direction.
        let usedLength: Double
        /// Share of the used fabric covered by piece bounding boxes.
        let efficiency: Double
    }

    private struct Rect { var x: Double, y: Double, w: Double, h: Double }
    private struct Item { var id: Int; var copy: Int; var w: Double; var h: Double }

    static func nest(pieces: [Piece], fabricWidth: Double, gap: Double = 0, allowRotation: Bool = false) throws -> Layout {
        guard fabricWidth.isFinite, fabricWidth > 0, gap.isFinite, gap >= 0,
              pieces.allSatisfy({ $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 && $0.copies >= 1 })
        else { throw NestingError.invalidInput }

        var items: [Item] = []
        for piece in pieces {
            let fitsAsIs = piece.width <= fabricWidth + 1e-9
            let fitsTurned = allowRotation && piece.height <= fabricWidth + 1e-9
            guard fitsAsIs || fitsTurned else { throw NestingError.pieceTooWide(id: piece.id, width: piece.width, fabricWidth: fabricWidth) }
            for copy in 0..<piece.copies { items.append(Item(id: piece.id, copy: copy, w: piece.width + gap, h: piece.height + gap)) }
        }
        guard !items.isEmpty else { return Layout(placements: [], fabricWidth: fabricWidth, usedLength: 0, efficiency: 0) }

        let orderings: [(Item, Item) -> Bool] = [
            { $0.w * $0.h > $1.w * $1.h },
            { $0.h > $1.h || ($0.h == $1.h && $0.w > $1.w) },
            { $0.w > $1.w || ($0.w == $1.w && $0.h > $1.h) },
            { max($0.w, $0.h) > max($1.w, $1.h) },
        ]
        var best: [Placement]?
        var bestLength = Double.infinity
        for order in orderings {
            let sorted = items.sorted { order($0, $1) || (!order($1, $0) && ($0.id, $0.copy) < ($1.id, $1.copy)) }
            guard let placed = pack(sorted, width: fabricWidth + gap, allowRotation: allowRotation, gap: gap) else { continue }
            let length = placed.map { $0.y + $0.height }.max() ?? 0
            if length < bestLength - 1e-12 { best = placed; bestLength = length }
        }
        guard let placements = best else { throw NestingError.invalidInput }
        let area = placements.reduce(0) { $0 + $1.width * $1.height }
        return Layout(placements: placements, fabricWidth: fabricWidth, usedLength: bestLength,
                      efficiency: bestLength > 0 ? area / (fabricWidth * bestLength) : 0)
    }

    private static func pack(_ items: [Item], width: Double, allowRotation: Bool, gap: Double) -> [Placement]? {
        let totalHeight = items.reduce(0) { $0 + max($1.h, allowRotation ? $1.w : 0) } + 1
        var free = [Rect(x: 0, y: 0, w: width, h: totalHeight)]
        var placements: [Placement] = []
        for item in items {
            var choice: (rect: Rect, rotated: Bool)?
            var score = (Double.infinity, Double.infinity)
            for rect in free {
                for rotated in allowRotation ? [false, true] : [false] {
                    let w = rotated ? item.h : item.w, h = rotated ? item.w : item.h
                    guard w <= rect.w + 1e-9, h <= rect.h + 1e-9 else { continue }
                    let candidate = (rect.y + h, rect.x)
                    if candidate < score { score = candidate; choice = (Rect(x: rect.x, y: rect.y, w: w, h: h), rotated) }
                }
            }
            guard let chosen = choice else { return nil }
            let placed = chosen.rect
            placements.append(Placement(id: item.id, copy: item.copy, x: placed.x, y: placed.y,
                                        width: placed.w - gap, height: placed.h - gap, rotated: chosen.rotated))
            var next: [Rect] = []
            for rect in free {
                if placed.x >= rect.x + rect.w || placed.x + placed.w <= rect.x || placed.y >= rect.y + rect.h || placed.y + placed.h <= rect.y {
                    next.append(rect); continue
                }
                if placed.x > rect.x { next.append(Rect(x: rect.x, y: rect.y, w: placed.x - rect.x, h: rect.h)) }
                if placed.x + placed.w < rect.x + rect.w { next.append(Rect(x: placed.x + placed.w, y: rect.y, w: rect.x + rect.w - placed.x - placed.w, h: rect.h)) }
                if placed.y > rect.y { next.append(Rect(x: rect.x, y: rect.y, w: rect.w, h: placed.y - rect.y)) }
                if placed.y + placed.h < rect.y + rect.h { next.append(Rect(x: rect.x, y: placed.y + placed.h, w: rect.w, h: rect.y + rect.h - placed.y - placed.h)) }
            }
            free = prune(next)
        }
        return placements
    }

    /// Drops free rectangles that lie entirely inside another.
    private static func prune(_ rects: [Rect]) -> [Rect] {
        var kept: [Rect] = []
        for (i, a) in rects.enumerated() {
            let contained = rects.enumerated().contains { j, b in
                j != i && a.x >= b.x - 1e-12 && a.y >= b.y - 1e-12 && a.x + a.w <= b.x + b.w + 1e-12 && a.y + a.h <= b.y + b.h + 1e-12
                    && (a.x != b.x || a.y != b.y || a.w != b.w || a.h != b.h || j < i)
            }
            if !contained { kept.append(a) }
        }
        return kept
    }
}

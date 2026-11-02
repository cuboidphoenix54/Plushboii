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

    // MARK: Shape-aware nesting

    struct Shape: Sendable {
        let id: Int
        /// Closed outline in centimetres, any origin.
        let outline: [Vec2]
        var copies = 1
    }

    struct ShapePlacement: Sendable, Equatable {
        let id: Int
        let copy: Int
        /// Translation applied to the outline after moving its lower-left bounding corner to the origin.
        let x: Double
        let y: Double
        let rotated180: Bool
    }

    struct ShapeLayout: Sendable, Equatable {
        let placements: [ShapePlacement]
        let fabricWidth: Double
        let usedLength: Double
        /// Outline area over used fabric area.
        let efficiency: Double
    }

    private struct Mask {
        let id: Int
        let copy: Int
        let rotated: Bool
        let rows: [[(start: Int, end: Int)]]
        let width: Int
        let area: Double
    }

    /// Rasterises each outline (plus `gap`) onto a `cell`-sized grid and places pieces first-fit, lowest row then leftmost,
    /// so a piece may nest into another's concave side. Cells touched by an outline are always occupied, so the result
    /// never overlaps; the grid resolution bounds how tight it can get. 180° turns are tried only when `allowRotation`
    /// is set, because they reverse pile direction.
    static func nestShapes(_ shapes: [Shape], fabricWidth: Double, gap: Double = 0.5, cell: Double = 1, allowRotation: Bool = false) throws -> ShapeLayout {
        guard fabricWidth.isFinite, fabricWidth > 0, gap.isFinite, gap >= 0, cell.isFinite, cell > 0,
              shapes.allSatisfy({ $0.outline.count >= 3 && $0.copies >= 1 && $0.outline.allSatisfy { $0.x.isFinite && $0.y.isFinite } })
        else { throw NestingError.invalidInput }
        let columns = Int((fabricWidth / cell).rounded(.down))
        let pad = Int((gap / cell).rounded(.up))
        var masks: [Mask] = []
        for shape in shapes {
            for rotated in allowRotation ? [false, true] : [false] {
                guard let mask = rasterise(shape, copy: 0, rotated: rotated, cell: cell, pad: pad) else { throw NestingError.invalidInput }
                guard mask.width <= columns else { throw NestingError.pieceTooWide(id: shape.id, width: Double(mask.width - 2 * pad) * cell, fabricWidth: fabricWidth) }
            }
        }
        var best: [ShapePlacement]?
        var bestRows = Int.max
        let orderings: [(Shape, Shape) -> Bool] = [
            { area($0) > area($1) },
            { ($0.outline.map(\.y).max() ?? 0) - ($0.outline.map(\.y).min() ?? 0) > ($1.outline.map(\.y).max() ?? 0) - ($1.outline.map(\.y).min() ?? 0) },
        ]
        for order in orderings {
            var queue: [(Shape, Int)] = []
            for shape in shapes.sorted(by: order) { for copy in 0..<shape.copies { queue.append((shape, copy)) } }
            var occupied: [[Bool]] = []
            var placements: [ShapePlacement] = []
            var rowsUsed = 0
            var ok = true
            for (shape, copy) in queue {
                var chosen: (x: Int, y: Int, mask: Mask)?
                for rotated in allowRotation ? [false, true] : [false] {
                    guard let mask = rasterise(shape, copy: copy, rotated: rotated, cell: cell, pad: pad) else { continue }
                    guard let spot = firstFit(mask, in: &occupied, columns: columns) else { continue }
                    let top = spot.y + mask.rows.count
                    if chosen == nil || top < chosen!.y + chosen!.mask.rows.count { chosen = (spot.x, spot.y, mask) }
                }
                guard let c = chosen else { ok = false; break }
                while occupied.count < c.y + c.mask.rows.count { occupied.append([Bool](repeating: false, count: columns)) }
                for (r, runs) in c.mask.rows.enumerated() {
                    for run in runs { for x in run.start...run.end { occupied[c.y + r][c.x + x] = true } }
                }
                rowsUsed = max(rowsUsed, c.y + c.mask.rows.count - pad)
                placements.append(ShapePlacement(id: shape.id, copy: copy, x: Double(c.x + pad) * cell, y: Double(c.y + pad) * cell, rotated180: c.mask.rotated))
            }
            if ok, rowsUsed < bestRows { best = placements; bestRows = rowsUsed }
        }
        guard let result = best else { throw NestingError.invalidInput }
        let length = Double(bestRows) * cell
        let total = shapes.reduce(0.0) { $0 + area($1) * Double($1.copies) }
        return ShapeLayout(placements: result, fabricWidth: fabricWidth, usedLength: length, efficiency: length > 0 ? total / (fabricWidth * length) : 0)
    }

    private static func area(_ shape: Shape) -> Double {
        var twice = 0.0
        for i in shape.outline.indices {
            let a = shape.outline[i], b = shape.outline[(i + 1) % shape.outline.count]
            twice += a.x * b.y - b.x * a.y
        }
        return abs(twice) / 2
    }

    private static func rasterise(_ shape: Shape, copy: Int, rotated: Bool, cell: Double, pad: Int) -> Mask? {
        var points = shape.outline
        if rotated { points = points.map { Vec2(-$0.x, -$0.y) } }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(), maxX > minX, maxY > minY else { return nil }
        let w = Int(((maxX - minX) / cell).rounded(.up)) + 1, h = Int(((maxY - minY) / cell).rounded(.up)) + 1
        var grid = [[Bool]](repeating: [Bool](repeating: false, count: w), count: h)
        let local = points.map { Vec2(($0.x - minX) / cell, ($0.y - minY) / cell) }
        for r in 0..<h {
            for c in 0..<w where contains(local, x: Double(c) + 0.5, y: Double(r) + 0.5) { grid[r][c] = true }
        }
        for i in local.indices {
            let a = local[i], b = local[(i + 1) % local.count]
            let steps = max(1, Int((vlength(b - a) * 2).rounded(.up)))
            for k in 0...steps {
                let q = a + (b - a) * (Double(k) / Double(steps))
                grid[min(h - 1, max(0, Int(q.y)))][min(w - 1, max(0, Int(q.x)))] = true
            }
        }
        let fullW = w + 2 * pad, fullH = h + 2 * pad
        var padded = [[Bool]](repeating: [Bool](repeating: false, count: fullW), count: fullH)
        for r in 0..<h {
            for c in 0..<w where grid[r][c] {
                for dr in -pad...pad { for dc in -pad...pad { padded[r + pad + dr][c + pad + dc] = true } }
            }
        }
        var rows: [[(start: Int, end: Int)]] = []
        for row in padded {
            var runs: [(start: Int, end: Int)] = []
            var start: Int?
            for (c, filled) in row.enumerated() {
                if filled, start == nil { start = c }
                if !filled, let s = start { runs.append((s, c - 1)); start = nil }
            }
            if let s = start { runs.append((s, fullW - 1)) }
            rows.append(runs)
        }
        return Mask(id: shape.id, copy: copy, rotated: rotated, rows: rows, width: fullW, area: area(shape))
    }

    private static func contains(_ polygon: [Vec2], x: Double, y: Double) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > y) != (b.y > y), x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    private static func firstFit(_ mask: Mask, in occupied: inout [[Bool]], columns: Int) -> (x: Int, y: Int)? {
        var y = 0
        while true {
            for x in 0...(columns - mask.width) {
                var fits = true
                rows: for (r, runs) in mask.rows.enumerated() where y + r < occupied.count {
                    let line = occupied[y + r]
                    for run in runs {
                        for c in run.start...run.end where line[x + c] { fits = false; break rows }
                    }
                }
                if fits { return (x, y) }
            }
            y += 1
            if y > occupied.count { return (0, occupied.count) }
        }
    }
}

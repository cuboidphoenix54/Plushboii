import Foundation

enum PatternUnits {
    static let pointsPerInch = 72.0
    static let pointsPerCentimeter = pointsPerInch / 2.54
    static let seamAllowancePoints = 0.25 * pointsPerInch
    /// Locked physical size of the scale-calibration square. It is a constant, never derived from the pattern scale.
    static let calibrationSidePoints = 5.0 * pointsPerCentimeter
}

enum PaperSize {
    static let a0 = Vec2(841.0 / 25.4 * 72, 1189.0 / 25.4 * 72)
    static let usLetter = Vec2(612, 792)
}

struct PlacedPiece: Sendable {
    let label: String
    let segmentIndex: Int
    /// Sewing line: the flattened island boundary as smooth Beziers.
    let seamLine: ClosedBezierPath
    /// Cutting line: the sewing line offset outward by 1/4 inch.
    let cutLine: ClosedBezierPath
    let unresolvedConcaveJoins: Int
}

/// A fully laid-out pattern in y-down page points (1 pt = 1/72 in), shared by the A0 and the tiled outputs.
struct PatternSheet: Sendable {
    let pageSize: Vec2
    let pieces: [PlacedPiece]
    let calibration: Rect2
    /// Extent of everything that is drawn; the tiled output only covers this area.
    let contentBounds: Rect2
}

enum PatternLayout {
    static let margin = 36.0
    static let gap = 18.0

    static func makeSheet(from result: FlatteningResult, centimetersPerUnit: Double) throws -> PatternSheet {
        guard centimetersPerUnit.isFinite, centimetersPerUnit > 0 else { throw PatternOutputError.invalidScale }
        guard !result.islands.isEmpty else { throw PatternOutputError.noIslands }
        let scale = centimetersPerUnit * PatternUnits.pointsPerCentimeter

        struct Prepared {
            let island: UVIsland
            let seam: ClosedBezierPath
            let cut: ClosedBezierPath
            let joins: Int
        }

        let prepared: [Prepared] = try result.islands.map { island in
            let boundary = try PatternGeometry.boundaryLoop(of: island).map { $0 * scale }
            let seam = PatternGeometry.smoothClosedPath(through: boundary)
            let offset = try PatternGeometry.offset(seam, distance: PatternUnits.seamAllowancePoints, segmentIndex: island.segmentIndex)
            return Prepared(island: island, seam: seam, cut: offset.path, joins: offset.unresolvedConcaveJoins)
        }

        let order = prepared.indices.sorted {
            let a = prepared[$0].cut.bounds.height, b = prepared[$1].cut.bounds.height
            return a == b ? $0 < $1 : a > b
        }

        for page in [PaperSize.a0, Vec2(PaperSize.a0.y, PaperSize.a0.x)] {
            if let placed = pack(prepared.map { $0.cut.bounds }, order: order, page: page) {
                let pieces = prepared.indices.map { index -> PlacedPiece in
                    let origin = placed.origins[index]
                    let bounds = prepared[index].cut.bounds
                    // UV space is y-up; pages are y-down. Mirroring the numbers keeps the drawn shape unchanged.
                    let move: (Vec2) -> Vec2 = { Vec2($0.x - bounds.minX + origin.x, -($0.y) - (-bounds.maxY) + origin.y) }
                    return PlacedPiece(
                        label: "Piece \(prepared[index].island.segmentIndex + 1)",
                        segmentIndex: prepared[index].island.segmentIndex,
                        seamLine: prepared[index].seam.mapped(move),
                        cutLine: prepared[index].cut.mapped(move),
                        unresolvedConcaveJoins: prepared[index].joins
                    )
                }
                let calibration = Rect2(minX: margin, minY: margin, maxX: margin + PatternUnits.calibrationSidePoints, maxY: margin + PatternUnits.calibrationSidePoints)
                let content = pieces.reduce(calibration) { $0.union($1.cutLine.bounds) }
                let bounds = Rect2(minX: 0, minY: 0, maxX: content.maxX + margin, maxY: content.maxY + margin)
                return PatternSheet(pageSize: page, pieces: pieces, calibration: calibration, contentBounds: bounds)
            }
        }
        throw PatternOutputError.doesNotFitA0
    }

    /// Shelf packing below the calibration square. Returns top-left origins indexed like `boxes`, or nil if it does not fit.
    private static func pack(_ boxes: [Rect2], order: [Int], page: Vec2) -> (origins: [Vec2], height: Double)? {
        let maxX = page.x - margin, maxY = page.y - margin
        var origins = [Vec2](repeating: .zero, count: boxes.count)
        var x = margin
        var y = margin + PatternUnits.calibrationSidePoints + gap
        var shelfHeight = 0.0

        for index in order {
            let w = boxes[index].width, h = boxes[index].height
            if x > margin, x + w > maxX {
                x = margin
                y += shelfHeight + gap
                shelfHeight = 0
            }
            guard x + w <= maxX, y + h <= maxY else { return nil }
            origins[index] = Vec2(x, y)
            x += w + gap
            shelfHeight = max(shelfHeight, h)
        }
        return (origins, y + shelfHeight)
    }
}

/// How the sheet is cut into US Letter pages: a 0.5 in margin on every page holds crop marks and numbering,
/// and the remaining 7.5 x 10 in window carries the pattern. Tiles that would print blank are skipped.
struct TilePlan: Sendable, Equatable {
    static let margin = 36.0
    static let pageSize = PaperSize.usLetter
    static let windowSize = Vec2(pageSize.x - 2 * margin, pageSize.y - 2 * margin)

    struct Tile: Sendable, Equatable {
        let row: Int
        let column: Int
        let pageNumber: Int
    }

    let rows: Int
    let columns: Int
    let tiles: [Tile]

    init(sheet: PatternSheet) {
        let window = TilePlan.windowSize
        let columns = max(1, Int((sheet.contentBounds.maxX / window.x).rounded(.up)))
        let rows = max(1, Int((sheet.contentBounds.maxY / window.y).rounded(.up)))
        var tiles: [Tile] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let rect = Rect2(
                    minX: Double(column) * window.x, minY: Double(row) * window.y,
                    maxX: Double(column + 1) * window.x, maxY: Double(row + 1) * window.y
                )
                let occupied = rect.intersects(sheet.calibration) || sheet.pieces.contains { rect.intersects($0.cutLine.bounds) }
                if occupied { tiles.append(Tile(row: row, column: column, pageNumber: tiles.count + 1)) }
            }
        }
        self.rows = rows
        self.columns = columns
        self.tiles = tiles
    }
}

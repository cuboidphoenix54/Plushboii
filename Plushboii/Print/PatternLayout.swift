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

/// Text sitting in the seam allowance that names the piece to sew this edge to.
struct SeamLabel: Sendable, Equatable {
    let text: String
    let position: Vec2
    /// Reading direction in page space (radians, y-down), kept within ±90° so text is never upside down.
    let angle: Double
}

/// A short tick across the seam allowance. Both pieces sharing a seam get one at the same point along it.
struct Notch: Sendable, Equatable {
    let start: Vec2
    let end: Vec2
}

struct FurArrow: Sendable, Equatable {
    let start: Vec2
    let end: Vec2
}

/// An embroidery or applique detail transferred onto a piece, in page points.
struct PlacedDetail: Sendable, Equatable {
    let name: String
    let center: Vec2
    let radius: Double
    /// Rotation of the detail's "up" direction on the page (radians, 0 = pointing up the page).
    let rotation: Double
}

struct DetailSpec: Sendable {
    let name: String
    let position: Vec3
    /// 3D radius of the detail.
    let radius: Double
    let up: Vec3

    init(name: String, position: Vec3, radius: Double, up: Vec3 = Vec3(0, 1, 0)) {
        self.name = name
        self.position = position
        self.radius = radius
        self.up = up
    }
}

struct PlacedPiece: Sendable {
    let label: String
    let segmentIndex: Int
    /// Sewing line: the flattened island boundary as smooth Beziers.
    let seamLine: ClosedBezierPath
    /// Cutting line: the sewing line offset outward by 1/4 inch.
    let cutLine: ClosedBezierPath
    let unresolvedConcaveJoins: Int
    /// How many copies to cut in total (mirror copies included).
    var copies = 1
    /// How many of those copies are cut as the mirror image.
    var mirroredCopies = 0
    var seamLabels: [SeamLabel] = []
    var notches: [Notch] = []
    var furArrow: FurArrow?
    var details: [PlacedDetail] = []
    /// Sewing instructions (darts, gathers, eases) printed under the caption.
    var notes: [String] = []
    /// Dart apex positions in page points.
    var dartApexes: [Vec2] = []
    /// Seam allowance used to build `cutLine`, in points.
    var seamAllowancePoints = PatternUnits.seamAllowancePoints
}

struct LayoutOptions: Sendable {
    /// Piece names by island index; unnamed pieces are "Piece N".
    var names: [Int: String] = [:]
    /// Print congruent pieces once, with the number of copies noted.
    var deduplicateCongruent = false
    var labelSeams = false
    /// Mark one matching notch at the middle of every seam shared with another piece.
    var markNotches = false
    /// Distance between sewing line and cutting line, in points.
    var seamAllowancePoints = PatternUnits.seamAllowancePoints
    /// Print dart apexes and join notes (ease, gather) on each piece.
    var includeSewingNotes = false
    /// Nap direction on the page in degrees, 0 = along +x, 90 = down the page. Nil omits fur arrows.
    var furDirectionDegrees: Double?
    var details: [DetailSpec] = []
    /// Original mesh positions; required to place `details`.
    var meshPositions: [Vec3] = []
}

/// A fully laid-out pattern in y-down page points (1 pt = 1/72 in), shared by the A0 and the tiled outputs.
struct PatternSheet: Sendable {
    let pageSize: Vec2
    let pieces: [PlacedPiece]
    let calibration: Rect2
    /// Extent of everything that is drawn; the tiled output only covers this area.
    let contentBounds: Rect2
    /// True when the pieces are too big for any A0 page, so the sheet is only meant for the multi-page US Letter output.
    var isOversized = false
}

enum PatternLayout {
    static let margin = 36.0
    static let gap = 18.0

    static func makeSheet(
        from result: FlatteningResult,
        centimetersPerUnit: Double,
        options: LayoutOptions = LayoutOptions()
    ) throws -> PatternSheet {
        guard centimetersPerUnit.isFinite, centimetersPerUnit > 0 else { throw PatternOutputError.invalidScale }
        guard !result.islands.isEmpty else { throw PatternOutputError.noIslands }
        let scale = centimetersPerUnit * PatternUnits.pointsPerCentimeter

        let groups: [PieceCongruence.Group] = options.deduplicateCongruent
            ? PieceCongruence.groups(for: result)
            : result.islands.indices.map { PieceCongruence.Group(representative: $0, members: [.init(island: $0, mirrored: false)]) }
        var representative = [Int](repeating: 0, count: result.islands.count)
        for group in groups { for member in group.members { representative[member.island] = group.representative } }
        func name(of island: Int) -> String {
            let rep = representative[island]
            return options.names[rep] ?? "Piece \(result.islands[rep].segmentIndex + 1)"
        }
        let sections = (options.labelSeams || options.markNotches) ? SeamSections.sections(for: result) : []
        let sewingNotes = options.includeSewingNotes
            ? SewingGuide.notes(for: result, centimetersPerUnit: centimetersPerUnit)
            : []

        struct Prepared {
            let island: UVIsland
            let group: PieceCongruence.Group
            let seam: ClosedBezierPath
            let cut: ClosedBezierPath
            let joins: Int
        }

        let prepared: [Prepared] = try groups.map { group in
            let island = result.islands[group.representative]
            let boundary = try PatternGeometry.boundaryLoop(of: island).map { $0 * scale }
            // Mesh outlines can curl tighter than the seam allowance, which makes the exact offset reverse.
            // Relax only the failing outlines, as little as needed.
            var lastError: Error = PatternOutputError.offsetDegenerate(segment: island.segmentIndex)
            for passes in [0, 2, 4, 8, 16, 32, 64] {
                let points = PatternGeometry.relaxed(boundary, passes: passes)
                let seam = PatternGeometry.smoothClosedPath(through: points)
                do {
                    let offset = try PatternGeometry.offset(seam, distance: options.seamAllowancePoints, segmentIndex: island.segmentIndex)
                    return Prepared(island: island, group: group, seam: seam, cut: offset.path, joins: offset.unresolvedConcaveJoins)
                } catch { lastError = error }
            }
            // Last resort: straight edges between (lightly smoothed) outline vertices always offset cleanly.
            var fallback: Prepared?
            for passes in [0, 4, 12, 32] {
                let polygon = PatternGeometry.smoothClosedPath(through: PatternGeometry.relaxed(boundary, passes: passes), allCorners: true)
                guard let offset = try? PatternGeometry.offset(polygon, distance: options.seamAllowancePoints, segmentIndex: island.segmentIndex) else { continue }
                let candidate = Prepared(island: island, group: group, seam: polygon, cut: offset.path, joins: offset.unresolvedConcaveJoins)
                if candidate.joins == 0 { return candidate }
                if fallback == nil || candidate.joins < fallback!.joins { fallback = candidate }
            }
            if let fallback { return fallback }
            throw lastError
        }

        let order = prepared.indices.sorted {
            let a = prepared[$0].cut.bounds.height, b = prepared[$1].cut.bounds.height
            return a == b ? $0 < $1 : a > b
        }

        let details: [(spec: DetailSpec, located: DetailPlacement.Located)] = options.details.compactMap { spec in
            guard !options.meshPositions.isEmpty,
                  let located = DetailPlacement.locate(point: spec.position, up: spec.up, in: result, positions: options.meshPositions),
                  located.distance <= max(spec.radius * 2, 1e-9)
            else { return nil }
            return (spec, located)
        }

        // A0 first; larger patterns fall back to an A0-wide roll of two or three A0 lengths, never scaled down.
        let a0 = PaperSize.a0
        let widest = prepared.map { $0.cut.bounds.width }.max() ?? 0
        let oversizedPage = Vec2(max(a0.x, widest + 2 * margin), .greatestFiniteMagnitude)
        for page in [a0, Vec2(a0.y, a0.x), Vec2(a0.x, a0.y * 2), Vec2(a0.x, a0.y * 3), oversizedPage] {
            if let placed = pack(prepared.map { $0.cut.bounds }, order: order, page: page) {
                let oversized = page == oversizedPage
                let pieces = prepared.indices.map { index -> PlacedPiece in
                    let origin = placed.origins[index]
                    let bounds = prepared[index].cut.bounds
                    // UV space is y-up; pages are y-down. Mirroring the numbers keeps the drawn shape unchanged.
                    let move: (Vec2) -> Vec2 = { Vec2($0.x - bounds.minX + origin.x, -($0.y) - (-bounds.maxY) + origin.y) }
                    let island = prepared[index].island
                    let group = prepared[index].group
                    var piece = PlacedPiece(
                        label: name(of: island.segmentIndex),
                        segmentIndex: island.segmentIndex,
                        seamLine: prepared[index].seam.mapped(move),
                        cutLine: prepared[index].cut.mapped(move),
                        unresolvedConcaveJoins: prepared[index].joins
                    )
                    piece.copies = group.copies
                    piece.mirroredCopies = group.mirroredCopies
                    piece.seamAllowancePoints = options.seamAllowancePoints
                    if island.segmentIndex < sewingNotes.count {
                        let guide = sewingNotes[group.representative]
                        piece.notes = guide.summaryLines
                        piece.dartApexes = guide.darts.map { move($0.apexUV * scale) }
                    }

                    if options.markNotches, island.segmentIndex < sections.count,
                       let loop = try? PatternGeometry.boundaryIndices(of: island) {
                        piece.notches = seamNotches(
                            sections: sections[island.segmentIndex], loop: loop, island: island,
                            scale: scale, allowance: options.seamAllowancePoints, move: move
                        )
                    }
                    if options.labelSeams, island.segmentIndex < sections.count,
                       let loop = try? PatternGeometry.boundaryIndices(of: island) {
                        piece.seamLabels = seamLabels(
                            sections: sections[island.segmentIndex], loop: loop, island: island,
                            scale: scale, allowance: options.seamAllowancePoints, move: move, name: name(of:)
                        )
                    }
                    if let degrees = options.furDirectionDegrees {
                        let box = prepared[index].cut.bounds
                        let center = move(Vec2((box.minX + box.maxX) / 2, (box.minY + box.maxY) / 2))
                        let radians = degrees * Double.pi / 180
                        let half = min(0.35 * min(box.width, box.height), 36)
                        let direction = Vec2(cos(radians), sin(radians))
                        piece.furArrow = FurArrow(start: center - direction * half, end: center + direction * half)
                    }
                    piece.details = details.filter { $0.located.island == island.segmentIndex }.map { detail in
                        PlacedDetail(
                            name: detail.spec.name,
                            center: move(detail.located.uv * scale),
                            radius: detail.spec.radius * detail.located.scale * scale,
                            rotation: -detail.located.rotation
                        )
                    }
                    return piece
                }
                let calibration = Rect2(minX: margin, minY: margin, maxX: margin + PatternUnits.calibrationSidePoints, maxY: margin + PatternUnits.calibrationSidePoints)
                let content = pieces.reduce(calibration) { $0.union($1.cutLine.bounds) }
                let bounds = Rect2(minX: 0, minY: 0, maxX: content.maxX + margin, maxY: content.maxY + margin)
                var sheet = PatternSheet(
                    pageSize: oversized ? Vec2(page.x, bounds.maxY) : page,
                    pieces: pieces, calibration: calibration, contentBounds: bounds
                )
                sheet.isOversized = oversized
                return sheet
            }
        }
        throw PatternOutputError.doesNotFitA0
    }

    /// One notch at the topological middle of each long seam section shared with another piece. The middle
    /// vertex (even edge count) or middle edge (odd count) is the same on both pieces whatever their distortion.
    static func seamNotches(
        sections: [SeamSection],
        loop: [Int32],
        island: UVIsland,
        scale: Double,
        allowance: Double,
        move: (Vec2) -> Vec2
    ) -> [Notch] {
        let minimumLength = 40.0
        let n = loop.count
        guard n >= 3 else { return [] }
        func point(_ k: Int) -> Vec2 { island.uv[Int(loop[((k % n) + n) % n])] * scale }
        var notches: [Notch] = []
        for section in sections {
            guard let partner = section.partner, partner != island.segmentIndex else { continue }
            var length = 0.0
            for k in section.start..<(section.start + section.count) { length += vlength(point(k + 1) - point(k)) }
            guard length >= minimumLength else { continue }

            let middle = section.start + section.count / 2
            let base: Vec2, tangent: Vec2
            if section.count % 2 == 0 {
                base = point(middle)
                tangent = point(middle + 1) - point(middle - 1)
            } else {
                base = (point(middle) + point(middle + 1)) / 2
                tangent = point(middle + 1) - point(middle)
            }
            let span = vlength(tangent)
            guard span > 1e-9 else { continue }
            let unitTangent = tangent / span
            let outward = Vec2(unitTangent.y, -unitTangent.x)
            notches.append(Notch(start: move(base), end: move(base + outward * (allowance * 0.6))))
        }
        return notches
    }

    /// One label per sufficiently long seam section, centered in the seam allowance of that section's middle edge.
    private static func seamLabels(
        sections: [SeamSection],
        loop: [Int32],
        island: UVIsland,
        scale: Double,
        allowance: Double,
        move: (Vec2) -> Vec2,
        name: (Int) -> String
    ) -> [SeamLabel] {
        let minimumLength = 40.0
        var labels: [SeamLabel] = []
        for section in sections {
            guard let partner = section.partner else { continue }
            func point(_ k: Int) -> Vec2 { island.uv[Int(loop[k % loop.count])] * scale }
            var length = 0.0
            for k in section.start..<(section.start + section.count) { length += vlength(point(k + 1) - point(k)) }
            guard length >= minimumLength else { continue }

            let k = section.start + section.count / 2
            let a = point(k), b = point(k + 1)
            let span = vlength(b - a)
            guard span > 1e-9 else { continue }
            let tangent = (b - a) / span
            let outward = Vec2(tangent.y, -tangent.x)
            let anchor = (a + b) / 2 + outward * (allowance * 0.5)
            let page0 = move(anchor), page1 = move(anchor + tangent)
            var angle = atan2(page1.y - page0.y, page1.x - page0.x)
            if angle > Double.pi / 2 { angle -= Double.pi }
            if angle < -Double.pi / 2 { angle += Double.pi }
            labels.append(SeamLabel(text: partner == island.segmentIndex ? "Dart" : name(partner), position: page0, angle: angle))
        }
        return labels
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

/// Chooses a finished plush height per object. Pattern pieces scale linearly with height, so the tallest plush whose
/// pieces still fit the fabric width follows directly from one layout at any provisional height.
enum PlushSizing {
    struct Preset: Sendable, Equatable {
        let name: String
        let centimeters: Double
    }

    /// Commonly sold plush heights; typical categories, not a formal standard.
    static let presets: [Preset] = [
        Preset(name: "Mini", centimeters: 15), Preset(name: "Small", centimeters: 25), Preset(name: "Medium", centimeters: 35),
        Preset(name: "Standard", centimeters: 50), Preset(name: "Large", centimeters: 70), Preset(name: "Jumbo", centimeters: 90)
    ]
    /// Fabric width kept free for selvedges and the nesting gap, in cm.
    static let fabricMargin = 4.0
    /// Automatic sizing never goes above this; larger plushies are chosen explicitly.
    static let automaticMaximumCentimeters = 50.0

    /// Width in cm of the narrowest side of the widest piece's cut line (pieces may be turned on the fabric).
    static func widestPieceCentimeters(of sheet: PatternSheet) -> Double {
        sheet.pieces.map { piece -> Double in
            let points = piece.cutLine.sampled(perSegment: 8)
            guard let first = points.first else { return 0 }
            var box = Rect2(minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
            for point in points { box = box.union(Rect2(minX: point.x, minY: point.y, maxX: point.x, maxY: point.y)) }
            return min(box.width, box.height) / PatternUnits.pointsPerCentimeter
        }.max() ?? 0
    }

    /// Tallest plush, in cm, whose widest piece still fits the fabric. Nil when the allowance alone exceeds the fabric
    /// or there is nothing to measure.
    static func fittingHeight(
        currentHeight: Double, widestPieceCentimeters: Double, fabricWidthCentimeters: Double, seamAllowancePoints: Double
    ) -> Double? {
        let allowance = 2 * seamAllowancePoints / PatternUnits.pointsPerCentimeter
        let pattern = widestPieceCentimeters - allowance, room = fabricWidthCentimeters - fabricMargin - allowance
        guard currentHeight.isFinite, currentHeight > 0, pattern > 1e-9, room > 0 else { return nil }
        return currentHeight * room / pattern
    }

    /// Largest preset not above `limit`; below the smallest preset it falls back to whole centimeters.
    static func recommendedHeight(limit: Double) -> Double {
        guard limit.isFinite, limit > 0 else { return presets[0].centimeters }
        return presets.last(where: { $0.centimeters <= limit + 1e-9 })?.centimeters ?? max(1, limit.rounded(.down))
    }

    static func name(for centimeters: Double) -> String? {
        presets.first(where: { abs($0.centimeters - centimeters) < 1e-6 })?.name
    }

    /// One-line summary listing which common heights fit the fabric for this object.
    static func advice(chosen: Double, fitting: Double?, fabricWidthCentimeters: Double) -> String {
        let label = name(for: chosen).map { "\($0) " } ?? ""
        guard let fitting else { return String(format: "Size: %@%.0f cm.", label, chosen) }
        let fits = presets.filter { $0.centimeters <= fitting + 1e-9 }.map { "\($0.name) \(Int($0.centimeters)) cm" }
        let list = fits.isEmpty ? "none of the common sizes" : fits.joined(separator: ", ")
        return String(
            format: "Size: %@%.0f cm. Widest piece fits %.0f cm fabric up to %.0f cm tall; common sizes that fit: %@. Set a height to override.",
            label, chosen, fabricWidthCentimeters, fitting, list)
    }
}

extension PlushSizing {
    /// Nests with the pattern's own orientation; pieces wider than the fabric are turned 90° when that makes them fit.
    static func nest(_ shapes: [FabricNesting.Shape], fabricWidth: Double) throws -> (layout: FabricNesting.ShapeLayout, turned: Bool) {
        var turned = false
        let prepared = shapes.map { shape -> FabricNesting.Shape in
            let xs = shape.outline.map(\.x), ys = shape.outline.map(\.y)
            guard let width = xs.max().map({ $0 - xs.min()! }), let height = ys.max().map({ $0 - ys.min()! }),
                  width > fabricWidth - fabricMargin, height < width else { return shape }
            turned = true
            return FabricNesting.Shape(id: shape.id, outline: shape.outline.map { Vec2(-$0.y, $0.x) }, copies: shape.copies)
        }
        return (try FabricNesting.nestShapes(prepared, fabricWidth: fabricWidth), turned)
    }
}

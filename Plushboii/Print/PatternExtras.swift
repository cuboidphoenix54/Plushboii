import Foundation

/// Fabric needed to cut a pattern, from the laid-out sheet.
enum FabricCuttingPlanner {
    struct Placement: Sendable, Equatable {
        let label: String
        let mirrored: Bool
        /// Top-left corner and size, in centimeters from the fabric's corner (y runs along the fabric length).
        let x: Double, y: Double, width: Double, height: Double
    }

    struct Plan: Sendable, Equatable {
        let fabric: String
        let widthCm: Double
        /// Length of fabric required including the end-of-roll allowance.
        let lengthCm: Double
        let placements: [Placement]
        /// Share of the used rectangle covered by piece bounding boxes (an upper bound on true coverage).
        let utilization: Double
    }

    enum PlanningError: LocalizedError, Equatable {
        case invalidWidth(String)
        case pieceWiderThanFabric(piece: String, pieceCm: Double, fabricCm: Double)

        var errorDescription: String? {
            switch self {
            case .invalidWidth(let fabric):
                "The width for \(fabric) must be a positive number of centimeters."
            case .pieceWiderThanFabric(let piece, let pieceCm, let fabricCm):
                "\(piece) is \(String(format: "%.1f", pieceCm)) cm wide, wider than the \(String(format: "%.1f", fabricCm)) cm fabric. Reduce the size, add seams, or use wider fabric."
            }
        }
    }

    static let defaultWidthCm = 110.0
    static let gapCm = 0.5
    static let endAllowanceCm = 5.0

    /// Packs every copy of every piece (nap along the fabric length, so pieces are never turned sideways)
    /// onto one strip per fabric. `assignments` maps a piece's `segmentIndex` to a fabric name.
    static func plan(
        sheet: PatternSheet,
        assignments: [Int: String] = [:],
        widthsCm: [String: Double] = [:],
        defaultFabric: String = "Fabric"
    ) throws -> [Plan] {
        struct Item { let label: String, mirrored: Bool, width: Double, height: Double }
        var byFabric: [String: [Item]] = [:]
        for piece in sheet.pieces {
            let box = piece.cutLine.bounds
            let w = box.width / PatternUnits.pointsPerCentimeter, h = box.height / PatternUnits.pointsPerCentimeter
            let fabric = assignments[piece.segmentIndex] ?? defaultFabric
            for copy in 0..<max(1, piece.copies) {
                byFabric[fabric, default: []].append(Item(label: piece.label, mirrored: copy >= piece.copies - piece.mirroredCopies && piece.mirroredCopies > 0, width: w, height: h))
            }
        }

        return try byFabric.keys.sorted().map { fabric in
            let width = widthsCm[fabric] ?? defaultWidthCm
            guard width.isFinite, width > 0 else { throw PlanningError.invalidWidth(fabric) }
            let items = byFabric[fabric]!.sorted { $0.height > $1.height }
            if let wide = items.first(where: { $0.width > width }) {
                throw PlanningError.pieceWiderThanFabric(piece: wide.label, pieceCm: wide.width, fabricCm: width)
            }

            var placements: [Placement] = []
            var x = 0.0, y = 0.0, shelf = 0.0, area = 0.0
            for item in items {
                if x > 0, x + item.width > width {
                    x = 0
                    y += shelf + gapCm
                    shelf = 0
                }
                placements.append(Placement(label: item.label, mirrored: item.mirrored, x: x, y: y, width: item.width, height: item.height))
                x += item.width + gapCm
                shelf = max(shelf, item.height)
                area += item.width * item.height
            }
            let used = y + shelf
            return Plan(
                fabric: fabric,
                widthCm: width,
                lengthCm: used + endAllowanceCm,
                placements: placements,
                utilization: used > 0 ? min(1, area / (width * used)) : 0
            )
        }
    }
}

/// Vector export for editing in other programs. Every piece is a group of cut line, sewing line,
/// label, seam labels, grain and details, so pieces can be moved and restyled individually.
enum PatternSVGExporter {
    struct Options: Sendable {
        var includeLabels = true
        var includeSeamAllowance = true
        var includeGrain = true
        var includeDetails = true
    }

    private static let millimetersPerPoint = 25.4 / 72

    static func svg(_ sheet: PatternSheet, options: Options = Options()) -> String {
        let b = sheet.contentBounds
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        var out = ""
        out += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(f(b.maxX * millimetersPerPoint))mm\" height=\"\(f(b.maxY * millimetersPerPoint))mm\" viewBox=\"0 0 \(f(b.maxX)) \(f(b.maxY))\">\n"

        let c = sheet.calibration
        out += "  <g id=\"calibration\" fill=\"none\" stroke=\"black\" stroke-width=\"1\">\n"
        out += "    <rect x=\"\(f(c.minX))\" y=\"\(f(c.minY))\" width=\"\(f(c.width))\" height=\"\(f(c.height))\"/>\n"
        out += "    <text x=\"\(f((c.minX + c.maxX) / 2))\" y=\"\(f(c.minY + 14))\" font-size=\"10\" text-anchor=\"middle\" fill=\"black\" stroke=\"none\">5 cm x 5 cm</text>\n"
        out += "  </g>\n"

        for piece in sheet.pieces {
            let id = escape(piece.label) + "-\(piece.segmentIndex + 1)"
            out += "  <g id=\"piece-\(id)\" fill=\"none\" stroke=\"black\">\n"
            if options.includeSeamAllowance {
                out += "    <path id=\"cut-\(id)\" stroke-width=\"0.75\" d=\"\(pathData(piece.cutLine))\"/>\n"
            }
            out += "    <path id=\"sew-\(id)\" stroke-width=\"0.5\" stroke-dasharray=\"6 4\" d=\"\(pathData(piece.seamLine))\"/>\n"
            if options.includeLabels {
                let box = piece.seamLine.bounds
                var caption = escape(piece.label)
                if piece.copies > 1 {
                    caption += " - cut \(piece.copies)"
                    if piece.mirroredCopies > 0 { caption += " (\(piece.mirroredCopies) mirrored)" }
                }
                out += "    <text id=\"label-\(id)\" x=\"\(f((box.minX + box.maxX) / 2))\" y=\"\(f((box.minY + box.maxY) / 2))\" font-size=\"14\" text-anchor=\"middle\" fill=\"black\" stroke=\"none\">\(caption)</text>\n"
                for (i, note) in piece.notes.enumerated() {
                    out += "    <text id=\"note-\(id)-\(i)\" x=\"\(f((box.minX + box.maxX) / 2))\" y=\"\(f((box.minY + box.maxY) / 2 + 12 + 9 * Double(i)))\" font-size=\"7\" text-anchor=\"middle\" fill=\"black\" stroke=\"none\">\(escape(note))</text>\n"
                }
                for (i, apex) in piece.dartApexes.enumerated() {
                    out += "    <circle id=\"dart-\(id)-\(i)\" cx=\"\(f(apex.x))\" cy=\"\(f(apex.y))\" r=\"3\" stroke-width=\"0.5\" fill=\"none\"/>\n"
                }
                for (i, label) in piece.seamLabels.enumerated() {
                    out += "    <text id=\"seam-\(id)-\(i)\" x=\"0\" y=\"0\" font-size=\"6\" text-anchor=\"middle\" fill=\"black\" stroke=\"none\" transform=\"translate(\(f(label.position.x)) \(f(label.position.y))) rotate(\(f(label.angle * 180 / .pi)))\">\(escape(label.text))</text>\n"
                }
            }
            if options.includeGrain, let arrow = piece.furArrow {
                out += "    <path id=\"grain-\(id)\" stroke-width=\"0.75\" d=\"M \(f(arrow.start.x)) \(f(arrow.start.y)) L \(f(arrow.end.x)) \(f(arrow.end.y))\"/>\n"
            }
            if options.includeDetails {
                for (i, detail) in piece.details.enumerated() {
                    out += "    <circle id=\"detail-\(id)-\(i)\" cx=\"\(f(detail.center.x))\" cy=\"\(f(detail.center.y))\" r=\"\(f(max(detail.radius, 3)))\" stroke-width=\"0.5\"><title>\(escape(detail.name))</title></circle>\n"
                }
            }
            out += "  </g>\n"
        }
        out += "</svg>\n"
        return out
    }

    private static func pathData(_ path: ClosedBezierPath) -> String {
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        guard let first = path.segments.first else { return "" }
        var d = "M \(f(first.p0.x)) \(f(first.p0.y))"
        for s in path.segments {
            d += " C \(f(s.c1.x)) \(f(s.c1.y)), \(f(s.c2.x)) \(f(s.c2.y)), \(f(s.p3.x)) \(f(s.p3.y))"
        }
        return d + " Z"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

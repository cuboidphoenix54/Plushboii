import Foundation

/// ASCII DXF (AutoCAD R12 / AC1009) export for CAD and cutting software.
/// Units are millimetres, y is up, and each kind of line sits on its own layer.
/// Curves are flattened to polylines because R12 has no spline entity.
enum PatternDXFExporter {
    struct Options: Sendable {
        var includeLabels = true
        var includeSeamAllowance = true
        var includeGrain = true
        var includeDetails = true
        /// Straight segments per Bezier segment.
        var curveSubdivisions = 16
    }

    private static let millimetersPerPoint = 25.4 / 72

    private static let layers: [(name: String, color: Int)] = [
        ("CALIBRATION", 7), ("CUT", 1), ("SEW", 5), ("NOTCH", 3), ("GRAIN", 2), ("DETAIL", 6), ("LABEL", 7),
    ]

    static func dxf(_ sheet: PatternSheet, options: Options = Options()) -> String {
        let height = sheet.contentBounds.maxY
        func x(_ v: Double) -> Double { v * millimetersPerPoint }
        func y(_ v: Double) -> Double { (height - v) * millimetersPerPoint }
        func n(_ v: Double) -> String { String(format: "%.4f", v) }

        var out = ""
        func group(_ code: Int, _ value: String) { out += "\(code)\n\(value)\n" }

        group(0, "SECTION"); group(2, "HEADER")
        group(9, "$ACADVER"); group(1, "AC1009")
        group(0, "ENDSEC")

        group(0, "SECTION"); group(2, "TABLES")
        group(0, "TABLE"); group(2, "LAYER"); group(70, "\(layers.count)")
        for layer in layers {
            group(0, "LAYER"); group(2, layer.name); group(70, "0"); group(62, "\(layer.color)"); group(6, "CONTINUOUS")
        }
        group(0, "ENDTAB")
        group(0, "ENDSEC")

        group(0, "SECTION"); group(2, "ENTITIES")

        func line(_ layer: String, _ a: Vec2, _ b: Vec2) {
            group(0, "LINE"); group(8, layer)
            group(10, n(x(a.x))); group(20, n(y(a.y))); group(30, "0.0")
            group(11, n(x(b.x))); group(21, n(y(b.y))); group(31, "0.0")
        }
        func polyline(_ layer: String, _ points: [Vec2], closed: Bool) {
            group(0, "POLYLINE"); group(8, layer); group(66, "1"); group(70, closed ? "1" : "0")
            for p in points {
                group(0, "VERTEX"); group(8, layer)
                group(10, n(x(p.x))); group(20, n(y(p.y))); group(30, "0.0")
            }
            group(0, "SEQEND"); group(8, layer)
        }
        func circle(_ layer: String, _ c: Vec2, _ r: Double) {
            group(0, "CIRCLE"); group(8, layer)
            group(10, n(x(c.x))); group(20, n(y(c.y))); group(30, "0.0"); group(40, n(r * millimetersPerPoint))
        }
        func text(_ layer: String, _ at: Vec2, _ size: Double, _ value: String) {
            group(0, "TEXT"); group(8, layer)
            group(10, n(x(at.x))); group(20, n(y(at.y))); group(30, "0.0")
            group(40, n(size * millimetersPerPoint)); group(1, sanitize(value))
        }
        func flattened(_ path: ClosedBezierPath) -> [Vec2] {
            let steps = max(options.curveSubdivisions, 1)
            var points: [Vec2] = []
            for segment in path.segments {
                for k in 0..<steps { points.append(segment.point(at: Double(k) / Double(steps))) }
            }
            return points
        }

        let c = sheet.calibration
        polyline("CALIBRATION", [Vec2(c.minX, c.minY), Vec2(c.maxX, c.minY), Vec2(c.maxX, c.maxY), Vec2(c.minX, c.maxY)], closed: true)
        if options.includeLabels { text("CALIBRATION", Vec2(c.minX + 4, c.minY + 14), 8, "5 cm x 5 cm") }

        for piece in sheet.pieces {
            if options.includeSeamAllowance { polyline("CUT", flattened(piece.cutLine), closed: true) }
            polyline("SEW", flattened(piece.seamLine), closed: true)
            if options.includeLabels {
                let box = piece.seamLine.bounds
                var caption = piece.label
                if piece.copies > 1 {
                    caption += " - cut \(piece.copies)"
                    if piece.mirroredCopies > 0 { caption += " (\(piece.mirroredCopies) mirrored)" }
                }
                text("LABEL", Vec2((box.minX + box.maxX) / 2, (box.minY + box.maxY) / 2), 14, caption)
                for (i, note) in piece.notes.enumerated() {
                    text("LABEL", Vec2((box.minX + box.maxX) / 2, (box.minY + box.maxY) / 2 + 12 + 9 * Double(i)), 7, note)
                }
                for apex in piece.dartApexes { circle("DETAIL", apex, 3) }
            }
            if options.includeSeamAllowance {
                for notch in piece.notches { line("NOTCH", notch.start, notch.end) }
            }
            if options.includeGrain, let arrow = piece.furArrow { line("GRAIN", arrow.start, arrow.end) }
            if options.includeDetails {
                for detail in piece.details { circle("DETAIL", detail.center, max(detail.radius, 3)) }
            }
        }
        group(0, "ENDSEC")
        group(0, "EOF")
        return out
    }

    /// DXF text values are single lines; control characters would corrupt the group structure.
    private static func sanitize(_ value: String) -> String {
        String(value.unicodeScalars.map { $0.value < 32 || $0.value == 127 ? " " : Character($0) })
    }
}

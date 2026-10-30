#if canImport(CoreGraphics) && canImport(CoreText)
import CoreGraphics
import CoreText
import Foundation

/// Draws a `PatternSheet` with Core Graphics. All drawing is in y-down page points; callers flip the context
/// (PDF contexts are y-up, flipped `NSView`s already are y-down).
enum PatternRenderer {
    static func cgPath(_ path: ClosedBezierPath) -> CGPath {
        let result = CGMutablePath()
        result.move(to: CGPoint(x: path.segments[0].p0.x, y: path.segments[0].p0.y))
        for s in path.segments {
            result.addCurve(
                to: CGPoint(x: s.p3.x, y: s.p3.y),
                control1: CGPoint(x: s.c1.x, y: s.c1.y),
                control2: CGPoint(x: s.c2.x, y: s.c2.y)
            )
        }
        result.closeSubpath()
        return result
    }

    static func drawSheetContent(_ sheet: PatternSheet, in ctx: CGContext) {
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineCap(.butt)
        ctx.setLineJoin(.miter)

        for piece in sheet.pieces {
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setLineWidth(0.75)
            ctx.addPath(cgPath(piece.cutLine))
            ctx.strokePath()

            ctx.setLineDash(phase: 0, lengths: [6, 4])
            ctx.setLineWidth(0.5)
            ctx.addPath(cgPath(piece.seamLine))
            ctx.strokePath()

            let b = piece.seamLine.bounds
            drawText(piece.label, at: CGPoint(x: (b.minX + b.maxX) / 2, y: (b.minY + b.maxY) / 2), size: 14, centered: true, in: ctx)
        }

        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setLineWidth(1)
        let square = CGRect(x: sheet.calibration.minX, y: sheet.calibration.minY, width: sheet.calibration.width, height: sheet.calibration.height)
        ctx.stroke(square)
        let mid = CGPoint(x: square.midX, y: square.midY)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: square.minX, y: mid.y)); ctx.addLine(to: CGPoint(x: square.maxX, y: mid.y))
        ctx.move(to: CGPoint(x: mid.x, y: square.minY)); ctx.addLine(to: CGPoint(x: mid.x, y: square.maxY))
        ctx.strokePath()
        drawText("5 cm x 5 cm", at: CGPoint(x: mid.x, y: square.minY + 14), size: 10, centered: true, in: ctx)
        drawText("Print at 100% / Actual Size", at: CGPoint(x: mid.x, y: square.maxY - 8), size: 7, centered: true, in: ctx)
        drawText("Measure this square before cutting", at: CGPoint(x: square.minX, y: square.maxY + 12), size: 7, centered: false, in: ctx)
    }

    /// Draws one US Letter page of the tiled layout. The context origin is the page's top-left corner.
    static func drawTile(_ tile: TilePlan.Tile, of plan: TilePlan, sheet: PatternSheet, in ctx: CGContext) {
        let m = TilePlan.margin, window = TilePlan.windowSize

        ctx.saveGState()
        ctx.clip(to: CGRect(x: m, y: m, width: window.x, height: window.y))
        ctx.translateBy(x: m - Double(tile.column) * window.x, y: m - Double(tile.row) * window.y)
        drawSheetContent(sheet, in: ctx)
        ctx.restoreGState()

        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setLineWidth(0.5)
        let left = m, right = m + window.x, top = m, bottom = m + window.y
        for (x, dx) in [(left, -1.0), (right, 1.0)] {
            for (y, dy) in [(top, -1.0), (bottom, 1.0)] {
                ctx.move(to: CGPoint(x: x + dx * 4, y: y)); ctx.addLine(to: CGPoint(x: x + dx * 26, y: y))
                ctx.move(to: CGPoint(x: x, y: y + dy * 4)); ctx.addLine(to: CGPoint(x: x, y: y + dy * 26))
            }
        }
        // Edge ticks at the midpoints help align neighbouring pages along a shared edge.
        let midX = (left + right) / 2, midY = (top + bottom) / 2
        ctx.move(to: CGPoint(x: midX, y: top - 4)); ctx.addLine(to: CGPoint(x: midX, y: top - 14))
        ctx.move(to: CGPoint(x: midX, y: bottom + 4)); ctx.addLine(to: CGPoint(x: midX, y: bottom + 14))
        ctx.move(to: CGPoint(x: left - 4, y: midY)); ctx.addLine(to: CGPoint(x: left - 14, y: midY))
        ctx.move(to: CGPoint(x: right + 4, y: midY)); ctx.addLine(to: CGPoint(x: right + 14, y: midY))
        ctx.strokePath()

        let caption = "Page \(tile.pageNumber) of \(plan.tiles.count)   Row \(tile.row + 1)/\(plan.rows)  Column \(tile.column + 1)/\(plan.columns)"
        drawText(caption, at: CGPoint(x: TilePlan.pageSize.x / 2, y: TilePlan.pageSize.y - 14), size: 9, centered: true, in: ctx)
    }

    static func drawText(_ text: String, at point: CGPoint, size: CGFloat, centered: Bool, in ctx: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: point.x - (centered ? width / 2 : 0), y: point.y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
#endif

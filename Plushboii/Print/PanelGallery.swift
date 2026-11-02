import Foundation

/// One flattened panel, ready to preview: sewing and cutting outlines in points with the top-left of the cut line at the origin.
struct PanelCard: Sendable, Identifiable {
    let id: String
    let pieceName: String
    let title: String
    let seamLine: ClosedBezierPath
    let cutLine: ClosedBezierPath
    let widthCentimeters: Double
    let heightCentimeters: Double
    let areaDelta: Double
    let notes: [String]
    let dartApexes: [Vec2]
    let copies: Int
    let mirroredCopies: Int
}

enum PanelGallery {
    /// Builds one card per flattened panel of a piece using the same layout code as the printed pattern,
    /// so the preview shows exactly the seam allowance, darts and join notes that will be printed.
    static func cards(
        pieceName: String,
        result: FlatteningResult,
        centimetersPerUnit: Double,
        seamAllowancePoints: Double,
        mergeIdentical: Bool = false
    ) throws -> [PanelCard] {
        var options = LayoutOptions()
        options.seamAllowancePoints = seamAllowancePoints
        options.includeSewingNotes = true
        options.deduplicateCongruent = mergeIdentical
        for index in result.islands.indices { options.names[index] = "\(pieceName) - panel \(index + 1)" }
        let sheet = try PatternLayout.makeSheet(from: result, centimetersPerUnit: centimetersPerUnit, options: options)

        return sheet.pieces.map { piece in
            let box = piece.cutLine.bounds
            let shift: (Vec2) -> Vec2 = { $0 - Vec2(box.minX, box.minY) }
            let delta = piece.segmentIndex < result.islands.count ? result.islands[piece.segmentIndex].report.areaDelta : 0
            return PanelCard(
                id: "\(pieceName)#\(piece.segmentIndex)",
                pieceName: pieceName,
                title: piece.label,
                seamLine: piece.seamLine.mapped(shift),
                cutLine: piece.cutLine.mapped(shift),
                widthCentimeters: box.width / PatternUnits.pointsPerCentimeter,
                heightCentimeters: box.height / PatternUnits.pointsPerCentimeter,
                areaDelta: delta,
                notes: piece.notes,
                dartApexes: piece.dartApexes.map(shift),
                copies: piece.copies,
                mirroredCopies: piece.mirroredCopies
            )
        }
    }
}

#if canImport(CoreGraphics) && canImport(PDFKit)
import CoreGraphics
import Foundation
import PDFKit

struct PatternOutputs: Sendable {
    let sheet: PatternSheet
    /// One continuous A0 page of vector paths for large-format plotters.
    let a0PDF: Data
    /// US Letter tiles with crop marks and sequential page numbers.
    let tiledPDF: Data
    let tiledPageCount: Int
}

enum PatternPrintPipeline {
    /// Lays out the flattened islands once, then renders both formats concurrently.
    /// Nothing is produced if any island has no valid outline or either PDF fails validation.
    static func export(result: FlatteningResult, centimetersPerUnit: Double) async throws -> PatternOutputs {
        let sheet = try PatternLayout.makeSheet(from: result, centimetersPerUnit: centimetersPerUnit)
        async let a0 = PatternPDFExporter.a0PDF(sheet)
        async let tiled = PatternPDFExporter.tiledPDF(sheet)
        let (a0Data, tiledResult) = try await (a0, tiled)
        return PatternOutputs(sheet: sheet, a0PDF: a0Data, tiledPDF: tiledResult.data, tiledPageCount: tiledResult.pages)
    }
}

enum PatternPDFExporter {
    static func a0PDF(_ sheet: PatternSheet) async throws -> Data {
        let size = CGSize(width: sheet.pageSize.x, height: sheet.pageSize.y)
        let data = try makePDF(pageSize: size, title: "Plushboii pattern (A0)", pages: 1) { ctx, _ in
            PatternRenderer.drawSheetContent(sheet, in: ctx)
        }
        try validate(data, pages: 1, pageSize: size)
        return data
    }

    static func tiledPDF(_ sheet: PatternSheet) async throws -> (data: Data, pages: Int) {
        let plan = TilePlan(sheet: sheet)
        let size = CGSize(width: TilePlan.pageSize.x, height: TilePlan.pageSize.y)
        let data = try makePDF(pageSize: size, title: "Plushboii pattern (US Letter tiles)", pages: plan.tiles.count) { ctx, index in
            PatternRenderer.drawTile(plan.tiles[index], of: plan, sheet: sheet, in: ctx)
        }
        try validate(data, pages: plan.tiles.count, pageSize: size)
        return (data, plan.tiles.count)
    }

    private static func makePDF(pageSize: CGSize, title: String, pages: Int, draw: (CGContext, Int) -> Void) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw PatternOutputError.pdfCreationFailed }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Plushboii"]
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else {
            throw PatternOutputError.pdfCreationFailed
        }
        for index in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.translateBy(x: 0, y: pageSize.height)
            ctx.scaleBy(x: 1, y: -1)
            draw(ctx, index)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    /// Reopens the bytes with PDFKit; a PDF that does not parse or has the wrong page count/size is never returned.
    private static func validate(_ data: Data, pages: Int, pageSize: CGSize) throws {
        guard let document = PDFDocument(data: data) else { throw PatternOutputError.pdfValidationFailed("the data is not a readable PDF") }
        guard document.pageCount == pages, pages > 0 else {
            throw PatternOutputError.pdfValidationFailed("expected \(pages) pages, found \(document.pageCount)")
        }
        guard let box = document.page(at: 0)?.bounds(for: .mediaBox),
              abs(box.width - pageSize.width) < 1, abs(box.height - pageSize.height) < 1 else {
            throw PatternOutputError.pdfValidationFailed("the page size is not \(Int(pageSize.width)) x \(Int(pageSize.height)) pt")
        }
    }
}
#endif

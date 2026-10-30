#if canImport(AppKit)
import AppKit

/// A flipped view holding the whole tile grid; `NSPrintOperation` asks it for one rect per US Letter page.
@MainActor
final class TiledPatternPrintView: NSView {
    private let sheet: PatternSheet
    private let plan: TilePlan

    init(sheet: PatternSheet) {
        let plan = TilePlan(sheet: sheet)
        let page = TilePlan.pageSize
        self.sheet = sheet
        self.plan = plan
        super.init(frame: NSRect(x: 0, y: 0, width: Double(plan.columns) * page.x, height: Double(plan.rows) * page.y))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: plan.tiles.count)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        guard plan.tiles.indices.contains(page - 1) else { return .zero }
        return pageRect(plan.tiles[page - 1])
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for tile in plan.tiles {
            let rect = pageRect(tile)
            guard rect.intersects(dirtyRect) else { continue }
            ctx.saveGState()
            ctx.translateBy(x: rect.minX, y: rect.minY)
            PatternRenderer.drawTile(tile, of: plan, sheet: sheet, in: ctx)
            ctx.restoreGState()
        }
    }

    private func pageRect(_ tile: TilePlan.Tile) -> NSRect {
        let page = TilePlan.pageSize
        return NSRect(x: Double(tile.column) * page.x, y: Double(tile.row) * page.y, width: page.x, height: page.y)
    }
}

enum PatternPrintOperation {
    /// US Letter, zero margins, clip pagination and a 100% scaling factor so one drawing point is one printed
    /// point. Printer-driver options such as "scale to fit" cannot be locked from here, which is what the
    /// 5 cm calibration square on the first page is for.
    @MainActor
    static func make(sheet: PatternSheet) -> NSPrintOperation {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: TilePlan.pageSize.x, height: TilePlan.pageSize.y)
        info.orientation = .portrait
        info.leftMargin = 0
        info.rightMargin = 0
        info.topMargin = 0
        info.bottomMargin = 0
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.scalingFactor = 1

        let operation = NSPrintOperation(view: TiledPatternPrintView(sheet: sheet), printInfo: info)
        operation.jobTitle = "Plushboii pattern"
        operation.printPanel.options.remove([.showsScaling, .showsPaperSize, .showsOrientation, .showsPageSetupAccessory])
        return operation
    }
}
#endif

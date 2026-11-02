import SwiftUI

struct PanelGalleryGroup: Identifiable, Sendable {
    let id: UUID
    let name: String
    let cards: [PanelCard]
    let failure: String?
}

struct PanelGalleryView: View {
    let groups: [PanelGalleryGroup]
    let allowance: SeamAllowanceOption
    let isScaled: Bool
    let isBusy: Bool
    let onFlattenAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Flattened panels").font(.headline)
                Text("Seam allowance \(allowance.displayName)").font(.caption).foregroundStyle(.secondary)
                if !isScaled {
                    Text("Not to scale: enter plush height or cm per mesh unit").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button("Flatten All Pieces", action: onFlattenAll).disabled(isBusy)
            }
            if groups.isEmpty {
                Text("No flattened pieces yet. Choose Flatten, or Flatten All Pieces.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(groups) { group in groupView(group) }
                    }
                }
            }
        }
        .padding()
    }

    private func groupView(_ group: PanelGalleryGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(group.name): \(group.cards.count) panel(s)").font(.subheadline.bold())
            if let failure = group.failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(group.cards) { card in cardView(card) }
                }
            }
        }
    }

    private func cardView(_ card: PanelCard) -> some View {
        let box = card.cutLine.bounds
        let side: CGFloat = 150
        let fit = side / max(box.width, box.height, 1)
        return VStack(alignment: .leading, spacing: 3) {
            Canvas { context, _ in
                let cut = Self.path(card.cutLine, scale: fit)
                let seam = Self.path(card.seamLine, scale: fit)
                context.stroke(cut, with: .color(.primary), lineWidth: 1)
                context.stroke(seam, with: .color(.secondary), style: StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
                for apex in card.dartApexes {
                    let r = CGRect(x: apex.x * fit - 3, y: apex.y * fit - 3, width: 6, height: 6)
                    context.stroke(Path(ellipseIn: r), with: .color(.red), lineWidth: 1)
                }
            }
            .frame(width: box.width * fit, height: box.height * fit)
            .frame(width: side, height: side)
            Text(card.title).font(.caption.bold()).lineLimit(1)
            Text(String(format: "%.1f × %.1f cm, area Δ %.1f%%", card.widthCentimeters, card.heightCentimeters, card.areaDelta * 100))
                .font(.caption2).foregroundStyle(.secondary)
            if card.copies > 1 {
                Text("Cut \(card.copies)" + (card.mirroredCopies > 0 ? " (\(card.mirroredCopies) mirrored)" : ""))
                    .font(.caption2)
            }
            ForEach(card.notes, id: \.self) { Text($0).font(.caption2).foregroundStyle(.orange) }
        }
        .frame(width: side + 16, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private static func path(_ bezier: ClosedBezierPath, scale: CGFloat) -> Path {
        var path = Path()
        guard let first = bezier.segments.first else { return path }
        path.move(to: CGPoint(x: first.p0.x * scale, y: first.p0.y * scale))
        for s in bezier.segments {
            path.addCurve(
                to: CGPoint(x: s.p3.x * scale, y: s.p3.y * scale),
                control1: CGPoint(x: s.c1.x * scale, y: s.c1.y * scale),
                control2: CGPoint(x: s.c2.x * scale, y: s.c2.y * scale)
            )
        }
        path.closeSubpath()
        return path
    }
}

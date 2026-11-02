import SwiftUI

/// Lets the user fix the MLX anatomy plan: move, relabel, add or delete cut planes, preview the split, and save the
/// corrected plan as a training example so the model can learn from it.
struct AnatomyCorrectionSheet: View {
    private struct EditableCut: Identifiable {
        let id = UUID()
        var axis: AnatomicalAxis
        var position: Double
        var boundary: String
        var negativeRegion: String
        var positiveRegion: String
        var confidence: Double

        init(_ cut: AnatomicalCut) {
            axis = cut.axis; position = cut.normalizedPosition; boundary = cut.boundary
            negativeRegion = cut.negativeRegion; positiveRegion = cut.positiveRegion; confidence = cut.confidence
        }

        var cut: AnatomicalCut {
            AnatomicalCut(axis: axis, normalizedPosition: position, boundary: boundary, negativeRegion: negativeRegion, positiveRegion: positiveRegion, confidence: confidence)
        }
    }

    let summary: String
    let canLearn: Bool
    let onPreview: @MainActor ([AnatomicalCut]) async -> String
    let onSaveForLearning: @MainActor ([AnatomicalCut], String) async -> String
    let onClose: @MainActor () -> Void

    @State private var cuts: [EditableCut]
    @State private var notes: String
    @State private var status = ""
    @State private var isBusy = false

    init(
        plan: AnatomicalCutPlan, canLearn: Bool,
        onPreview: @escaping @MainActor ([AnatomicalCut]) async -> String,
        onSaveForLearning: @escaping @MainActor ([AnatomicalCut], String) async -> String,
        onClose: @escaping @MainActor () -> Void
    ) {
        summary = plan.summary
        self.canLearn = canLearn
        self.onPreview = onPreview
        self.onSaveForLearning = onSaveForLearning
        self.onClose = onClose
        _cuts = State(initialValue: plan.cuts.map(EditableCut.init))
        _notes = State(initialValue: plan.summary)
    }

    private var current: [AnatomicalCut] { cuts.map(\.cut) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Correct Anatomy Cuts").font(.title2.bold())
            Text("Each cut is a plane across the mesh. Region names containing face, muzzle, snout, beak, nose, mouth, eye, cheek or forehead keep seams out of that side of the cut.")
                .font(.callout).foregroundStyle(.secondary)

            List {
                ForEach($cuts) { $cut in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Boundary", text: $cut.boundary)
                            Picker("Axis", selection: $cut.axis) {
                                ForEach(AnatomicalAxis.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                            }
                            .pickerStyle(.segmented).frame(width: 130)
                            Button(role: .destructive) { cuts.removeAll { $0.id == cut.id } } label: { Image(systemName: "trash") }
                                .accessibilityLabel("Delete cut")
                        }
                        HStack {
                            Slider(value: $cut.position, in: 0.02...0.98)
                            Text(String(format: "%.0f%%", cut.position * 100)).monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                        HStack {
                            TextField("Low side", text: $cut.negativeRegion)
                            Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                            TextField("High side", text: $cut.positiveRegion)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(minHeight: 220)

            HStack {
                Button("Add Cut") {
                    cuts.append(EditableCut(AnatomicalCut(axis: .y, normalizedPosition: 0.5, boundary: "new cut", negativeRegion: "Lower", positiveRegion: "Upper", confidence: 1)))
                }
                Spacer()
            }
            TextField("What was wrong with the model's plan? (saved with the example)", text: $notes, axis: .vertical).lineLimit(1...3)

            if !status.isEmpty { Text(status).font(.callout).foregroundStyle(.secondary) }

            HStack {
                Button("Close") { onClose() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save for MLX Learning") {
                    Task { isBusy = true; status = await onSaveForLearning(current, notes); isBusy = false }
                }
                .disabled(isBusy || cuts.isEmpty || !canLearn)
                .help(canLearn ? "Adds the corrected plan to the MLX training examples." : "Analyze anatomy first so the model's views are available.")
                Button("Preview Split") {
                    Task { isBusy = true; status = await onPreview(current); isBusy = false }
                }
                .disabled(isBusy || cuts.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 520)
    }
}

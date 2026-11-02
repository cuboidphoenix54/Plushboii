import CryptoKit
import Foundation

/// A user's correction of the MLX anatomy plan: replacement cut planes and/or regions where seams must stay hidden.
struct AnatomyCorrection: Codable, Equatable, Sendable {
    var summary: String?
    var cuts: [AnatomicalCut]?
    var visibleRegions: [VisibleRegion]?

    static func load(_ url: URL) throws -> AnatomyCorrection {
        do {
            return try JSONDecoder().decode(AnatomyCorrection.self, from: Data(contentsOf: url))
        } catch {
            throw PlushAgentError.unreadable("Could not read corrections file \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Normalized, validated replacement cuts, or nil when the correction does not replace the model's plan.
    var replacementCuts: [AnatomicalCut]? {
        guard let cuts, !cuts.isEmpty else { return nil }
        let valid = cuts.filter { $0.normalizedPosition.isFinite && (0...1).contains($0.normalizedPosition) }
        return valid.isEmpty ? nil : AnatomyCutPlanNormalizer.normalize(valid)
    }
}

/// Saves corrections as fine-tuning rows in the same chat format as the synthetic dataset, so the MLX model
/// can be retrained on what the user fixed.
enum AnatomyCorrectionStore {
    private struct Label: Codable {
        let summary: String
        let cuts: [AnatomicalCut]
    }
    private struct Message: Codable { let role: String; let content: String }
    private struct Row: Codable { let messages: [Message]; let images: [String] }

    /// Appends one training example to `corrections.jsonl` under `directory` and returns the example's folder name.
    @discardableResult
    static func record(views: [Data], summary: String, cuts: [AnatomicalCut], to directory: URL) throws -> String {
        guard !views.isEmpty, !cuts.isEmpty else { throw PlushAgentError.unreadable("A correction needs rendered views and at least one cut.") }
        var digest = SHA256()
        views.forEach { digest.update(data: $0) }
        let name = "correction_" + digest.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var images: [String] = []
        for (view, data) in zip(AnatomyMeshViewRenderer.View.allCases, views) {
            let file = "\(name)/\(view.rawValue).png"
            try data.write(to: directory.appendingPathComponent(file))
            images.append(file)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let label = String(decoding: try encoder.encode(Label(summary: summary, cuts: cuts)), as: UTF8.self)
        try label.write(to: folder.appendingPathComponent("label.json"), atomically: true, encoding: .utf8)
        let row = Row(messages: [Message(role: "user", content: OnDeviceSeamAdvisor.anatomyPrompt), Message(role: "assistant", content: label)], images: images)

        let file = directory.appendingPathComponent("corrections.jsonl")
        // The same views always hash to the same folder, so a repeat correction replaces the earlier row.
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let kept = existing.split(separator: "\n").filter { !$0.contains(name) }
        let lines = kept.map(String.init) + [String(decoding: try encoder.encode(row), as: UTF8.self)]
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return name
    }
}

extension AnatomyCorrectionStore {
    /// Builds a new dataset from `base` (train/valid/test jsonl plus image folders) with every saved correction added
    /// to the training split `repeatCount` times, since user fixes are rare and high value. Never modifies `base`
    /// or `corrections`. Image folders are linked rather than copied.
    @discardableResult
    static func merge(base: URL, corrections: URL, into output: URL, repeatCount: Int = 3) throws -> (baseTrain: Int, added: Int) {
        let fm = FileManager.default
        guard repeatCount >= 1 else { throw PlushAgentError.unreadable("repeat count must be at least 1.") }
        guard fm.fileExists(atPath: base.appendingPathComponent("train.jsonl").path) else {
            throw PlushAgentError.unreadable("\(base.path) has no train.jsonl.")
        }
        guard !fm.fileExists(atPath: output.appendingPathComponent("train.jsonl").path) else {
            throw PlushAgentError.unreadable("\(output.path) already holds a dataset; choose a new versioned directory.")
        }
        let correctionFile = corrections.appendingPathComponent("corrections.jsonl")
        let correctionLines = ((try? String(contentsOf: correctionFile, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !correctionLines.isEmpty else { throw PlushAgentError.unreadable("No saved corrections in \(corrections.path).") }

        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        for entry in try fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            let name = entry.lastPathComponent
            if name.hasSuffix(".jsonl") || name == "manifest.json" || name.hasPrefix(".") { continue }
            try fm.createSymbolicLink(at: output.appendingPathComponent(name), withDestinationURL: entry)
        }
        for entry in try fm.contentsOfDirectory(at: corrections, includingPropertiesForKeys: nil) where entry.lastPathComponent.hasPrefix("correction_") {
            try fm.createSymbolicLink(at: output.appendingPathComponent(entry.lastPathComponent), withDestinationURL: entry)
        }
        for name in ["valid.jsonl", "test.jsonl"] where fm.fileExists(atPath: base.appendingPathComponent(name).path) {
            try fm.copyItem(at: base.appendingPathComponent(name), to: output.appendingPathComponent(name))
        }
        let baseTrain = try String(contentsOf: base.appendingPathComponent("train.jsonl"), encoding: .utf8)
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let merged = baseTrain + Array((0..<repeatCount).map { _ in correctionLines }.joined())
        try (merged.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("train.jsonl"), atomically: true, encoding: .utf8)
        let manifest = #"{"schemaVersion":1,"task":"anatomy-cuts+corrections","baseTrain":\#(baseTrain.count),"corrections":\#(correctionLines.count),"correctionRepeat":\#(repeatCount)}"#
        try manifest.write(to: output.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        return (baseTrain.count, correctionLines.count * repeatCount)
    }
}

public enum CorrectionDataset {
    /// See `AnatomyCorrectionStore.merge`.
    @discardableResult
    public static func merge(base: URL, corrections: URL, into output: URL, repeatCount: Int = 3) throws -> (baseTrain: Int, added: Int) {
        try AnatomyCorrectionStore.merge(base: base, corrections: corrections, into: output, repeatCount: repeatCount)
    }
}

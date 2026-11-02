import Foundation
import TopologyKit

// plushagent <file.obj> [--out DIR] [--target-faces N] [--max-joints N] [--stretch WARP WEFT] [--mlx] [--adapter PATH] [--height CM] [--subject auto|creature|object] [--corrections FILE] [--learn-dir DIR] [--json]

var arguments = Array(CommandLine.arguments.dropFirst())

// plushagent merge-corrections BASE_DATASET CORRECTIONS_DIR NEW_DATASET [REPEAT]
if arguments.first == "merge-corrections" {
    guard arguments.count >= 4 else { FileHandle.standardError.write(Data("usage: plushagent merge-corrections BASE_DATASET CORRECTIONS_DIR NEW_DATASET [REPEAT]\n".utf8)); exit(2) }
    do {
        let counts = try CorrectionDataset.merge(
            base: URL(fileURLWithPath: arguments[1]), corrections: URL(fileURLWithPath: arguments[2]),
            into: URL(fileURLWithPath: arguments[3]), repeatCount: arguments.count > 4 ? Int(arguments[4]) ?? 3 : 3)
        print("Merged: \(counts.baseTrain) base rows + \(counts.added) correction rows -> \(arguments[3])/train.jsonl")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8)); exit(1)
    }
}
var options = PlushAgentOptions()
var wantsJSON = false
var useMLX = false
var adapterPath: String?
var plushHeight = 50.0
var inputPath: String?

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--out":
        guard !arguments.isEmpty else { fail("--out needs a directory") }
        options.outputDirectory = URL(fileURLWithPath: arguments.removeFirst(), isDirectory: true)
    case "--target-faces":
        guard let value = arguments.first.flatMap(Int.init), value >= 4 else { fail("--target-faces needs an integer >= 4") }
        arguments.removeFirst(); options.targetFaces = value
    case "--max-joints":
        guard let value = arguments.first.flatMap(Int.init), value >= 0 else { fail("--max-joints needs a non-negative integer") }
        arguments.removeFirst(); options.maximumJoints = value
    case "--stretch":
        guard arguments.count >= 2, let warp = Double(arguments[0]), let weft = Double(arguments[1]) else { fail("--stretch needs WARP and WEFT percentages") }
        arguments.removeFirst(2); options.warpStretchPercent = warp; options.weftStretchPercent = weft
    case "--mlx":
        useMLX = true
    case "--adapter":
        guard !arguments.isEmpty else { fail("--adapter needs a path") }
        adapterPath = arguments.removeFirst()
    case "--height":
        guard let value = arguments.first.flatMap(Double.init), value > 0 else { fail("--height needs centimeters") }
        arguments.removeFirst(); plushHeight = value
    case "--subject":
        guard let value = arguments.first.flatMap(SubjectOverride.init(rawValue:)) else { fail("--subject needs auto, creature or object") }
        arguments.removeFirst(); options.subject = value
    case "--corrections":
        guard !arguments.isEmpty else { fail("--corrections needs a JSON file") }
        options.correctionsFile = URL(fileURLWithPath: arguments.removeFirst())
    case "--learn-dir":
        guard !arguments.isEmpty else { fail("--learn-dir needs a directory") }
        options.learnDirectory = URL(fileURLWithPath: arguments.removeFirst())
    case "--json":
        wantsJSON = true
    case "-h", "--help":
        print("usage: plushagent <file.obj> [--out DIR] [--target-faces N] [--max-joints N] [--stretch WARP WEFT] [--mlx] [--adapter PATH] [--height CM] [--subject auto|creature|object] [--corrections FILE] [--learn-dir DIR] [--json]")
        exit(0)
    default:
        guard inputPath == nil, !argument.hasPrefix("-") else { fail("unexpected argument: \(argument)") }
        inputPath = argument
    }
}

guard let inputPath else { fail("usage: plushagent <file.obj> [options]") }

do {
    let report: PlushAgentReport
    if useMLX {
        let result = try await PlushAgent.runWithMLX(input: URL(fileURLWithPath: inputPath), options: options, adapterPath: adapterPath, plushHeightCentimeters: plushHeight)
        print("MLX summary: \(result.summary)")
        result.cuts.forEach { print("  cut: \($0)") }
        result.patternFiles.forEach { print("  pattern: \($0)") }
        report = result.report
    } else {
        report = try PlushAgent.run(input: URL(fileURLWithPath: inputPath), options: options)
    }
    if wantsJSON {
        print(String(decoding: try report.json(), as: UTF8.self))
    } else {
        print("Plush agent: \(report.input) — \(report.verdict.uppercased())")
        report.steps.forEach { print("  • \($0)") }
        report.construction.forEach { print("  ◦ \($0)") }
        for piece in report.pieces {
            let detail = piece.issue ?? piece.advisory ?? "\(piece.panelCount ?? 0) panel(s), area Δ \(String(format: "%.1f%%", (piece.worstAreaDelta ?? 0) * 100))"
            print("  [\(piece.index + 1)] \(piece.label): \(piece.faces) faces, \(piece.openings) opening(s) — \(detail)")
        }
        report.warnings.forEach { print("  ! \($0)") }
    }
    exit(report.verdict == "failed" ? 1 : 0)
} catch {
    fail(error.localizedDescription)
}

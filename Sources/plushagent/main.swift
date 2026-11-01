import Foundation
import TopologyKit

// plushagent <file.obj> [--out DIR] [--target-faces N] [--max-joints N] [--stretch WARP WEFT] [--json]

var arguments = Array(CommandLine.arguments.dropFirst())
var options = PlushAgentOptions()
var wantsJSON = false
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
    case "--json":
        wantsJSON = true
    case "-h", "--help":
        print("usage: plushagent <file.obj> [--out DIR] [--target-faces N] [--max-joints N] [--stretch WARP WEFT] [--json]")
        exit(0)
    default:
        guard inputPath == nil, !argument.hasPrefix("-") else { fail("unexpected argument: \(argument)") }
        inputPath = argument
    }
}

guard let inputPath else { fail("usage: plushagent <file.obj> [options]") }

do {
    let report = try PlushAgent.run(input: URL(fileURLWithPath: inputPath), options: options)
    if wantsJSON {
        print(String(decoding: try report.json(), as: UTF8.self))
    } else {
        print("Plush agent: \(report.input) — \(report.verdict.uppercased())")
        report.steps.forEach { print("  • \($0)") }
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

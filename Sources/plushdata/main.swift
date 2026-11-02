import Foundation
import TopologyKit

// plushdata <output-dir> [--count N] [--seed S] [--ranking-every N] [--persona-per-tool N]

var arguments = Array(CommandLine.arguments.dropFirst())
var count = 200
var seed: UInt64 = 1
var rankingEvery = 10
var personaPerTool = 12
var output: String?

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

if arguments.first == "views" {
    guard arguments.count == 3 else { fail("usage: plushdata views <file.obj> <output-dir>") }
    do {
        try SyntheticDataset.renderViews(
            of: URL(fileURLWithPath: arguments[1]),
            to: URL(fileURLWithPath: arguments[2], isDirectory: true)
        )
        print("Wrote front/side/top PNGs to \(arguments[2])")
        exit(0)
    } catch {
        fail(error.localizedDescription)
    }
}

if arguments.first == "personas" {
    guard arguments.count == 2 else { fail("usage: plushdata personas <output.jsonl>") }
    do {
        let rows = try PersonaDataset.rows(seed: 1, geometryPerTool: 12)
        try Data(rows.map { $0 + Data([0x0A]) }.joined()).write(to: URL(fileURLWithPath: arguments[1]))
        print("Wrote \(rows.count) persona examples to \(arguments[1])")
        exit(0)
    } catch {
        fail(error.localizedDescription)
    }
}

// plushdata objaverse-one <dataset-dir> <output-dir> <uid>
// Prints the training row on stdout, or one rejection reason on stderr and exits 3.
if arguments.first == "objaverse-one" {
    guard arguments.count == 4 else { fail("usage: plushdata objaverse-one <dataset-dir> <output-dir> <uid>") }
    let dataset = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let out = URL(fileURLWithPath: arguments[2], isDirectory: true)
    let uid = arguments[3]
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("plushdata-oxl-\(uid)", isDirectory: true)
    func reject(_ reason: String) -> Never {
        try? FileManager.default.removeItem(at: scratch)
        FileHandle.standardError.write(Data((reason + "\n").utf8))
        exit(3)
    }
    do {
        var options = PlushAgentOptions()
        options.outputDirectory = scratch
        options.creaturesOnly = true
        let report = try PlushAgent.run(input: dataset.appendingPathComponent("obj/\(uid).obj"), options: options)
        guard report.subjectKind == "creature" else { reject("not_creature") }
        guard report.steps.contains("Mesh is closed.") else { reject("open_mesh") }
        guard report.verdict == "ready" else { reject("verdict_\(report.verdict)") }
        guard (2...6).contains(report.joints.count) else { reject("joint_count") }
        guard let prepared = report.preparedMeshFile else { reject("no_prepared_mesh") }
        let row = try SyntheticDataset.realMeshRow(
            preparedOBJ: scratch.appendingPathComponent(prepared), joints: report.joints,
            imagesDirectory: out.appendingPathComponent("images/\(uid)", isDirectory: true),
            imagePrefix: "objaverse/images/\(uid)")
        try? FileManager.default.removeItem(at: scratch)
        FileHandle.standardOutput.write(row + Data([0x0A]))
        exit(0)
    } catch {
        reject("error: \(error.localizedDescription)")
    }
}

while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--count":
        guard let value = arguments.first.flatMap(Int.init), value > 0 else { fail("--count needs a positive integer") }
        arguments.removeFirst(); count = value
    case "--seed":
        guard let value = arguments.first.flatMap(UInt64.init) else { fail("--seed needs a non-negative integer") }
        arguments.removeFirst(); seed = value
    case "--ranking-every":
        guard let value = arguments.first.flatMap(Int.init), value >= 0 else { fail("--ranking-every needs a non-negative integer (0 disables ranking examples)") }
        arguments.removeFirst(); rankingEvery = value
    case "--persona-per-tool":
        guard let value = arguments.first.flatMap(Int.init), value >= 0 else { fail("--persona-per-tool needs a non-negative integer (0 disables persona examples)") }
        arguments.removeFirst(); personaPerTool = value
    default:
        guard output == nil, !argument.hasPrefix("-") else { fail("unexpected argument: \(argument)") }
        output = argument
    }
}
guard let output else { fail("usage: plushdata <output-dir> [--count N] [--seed S] [--ranking-every N] [--persona-per-tool N]") }

do {
    let summary = try SyntheticDataset.generate(count: count, seed: seed, outputDirectory: URL(fileURLWithPath: output, isDirectory: true), rankingEvery: rankingEvery, personaPerTool: personaPerTool)
    print("Wrote \(summary.written) examples (\(summary.skipped) skipped) to \(output)")
} catch {
    fail(error.localizedDescription)
}

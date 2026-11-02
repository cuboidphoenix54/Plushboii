import Foundation
import TopologyKit

// plushdata <output-dir> [--count N] [--seed S] [--ranking-every N]

var arguments = Array(CommandLine.arguments.dropFirst())
var count = 200
var seed: UInt64 = 1
var rankingEvery = 10
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
    default:
        guard output == nil, !argument.hasPrefix("-") else { fail("unexpected argument: \(argument)") }
        output = argument
    }
}
guard let output else { fail("usage: plushdata <output-dir> [--count N] [--seed S] [--ranking-every N]") }

do {
    let summary = try SyntheticDataset.generate(count: count, seed: seed, outputDirectory: URL(fileURLWithPath: output, isDirectory: true), rankingEvery: rankingEvery)
    print("Wrote \(summary.written) examples (\(summary.skipped) skipped) to \(output)")
} catch {
    fail(error.localizedDescription)
}

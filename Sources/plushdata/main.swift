import Foundation
import TopologyKit

// plushdata <output-dir> [--count N] [--seed S]

var arguments = Array(CommandLine.arguments.dropFirst())
var count = 200
var seed: UInt64 = 1
var output: String?

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
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
    default:
        guard output == nil, !argument.hasPrefix("-") else { fail("unexpected argument: \(argument)") }
        output = argument
    }
}
guard let output else { fail("usage: plushdata <output-dir> [--count N] [--seed S]") }

do {
    let summary = try SyntheticDataset.generate(count: count, seed: seed, outputDirectory: URL(fileURLWithPath: output, isDirectory: true))
    print("Wrote \(summary.written) examples (\(summary.skipped) skipped) to \(output)")
} catch {
    fail(error.localizedDescription)
}

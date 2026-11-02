import Foundation

/// Generates geometry-labelled anatomy examples from varied creature morphologies. Joint labels originate
/// from the constructed parts and are retained only when the app splitter accepts the resulting planes.
public enum SyntheticDataset {
  /// Renders the three advisor views (front/side/top PNGs) of a real OBJ, for evaluating the model on real files.
  public static func renderViews(of objURL: URL, to outputDirectory: URL) throws {
    let imported = try OBJMeshReader.read(try Data(contentsOf: objURL))
    let (positions, triangles) = imported.topologyInput
    let views = try AnatomyMeshViewRenderer.render(positions: positions, triangles: triangles)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    for (view, data) in zip(AnatomyMeshViewRenderer.View.allCases, views) {
      try data.write(to: outputDirectory.appendingPathComponent("\(view.rawValue).png"))
    }
  }

  private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
  }

  private struct Part {
    let name: String
    let center: Vec3
    let radii: Vec3
    /// Name of the part this one is attached to (`torso` for body-mounted parts).
    var parent: String = "torso"

    func distance(_ p: Vec3) -> Double {
      let q = (p - center) / radii
      return (vlength(q) - 1) * min(radii.x, radii.y, radii.z)
    }
  }

  private struct Creature {
    let torso: Part
    /// Appendages in addition to the torso; each is joined to the torso.
    let appendages: [Part]
    var parts: [Part] { [torso] + appendages }

    func field(_ p: Vec3) -> Double {
      let smoothing = 0.25
      return parts.dropFirst().reduce(torso.distance(p)) { a, part in
        let b = part.distance(p)
        let h = max(smoothing - abs(a - b), 0) / smoothing
        return min(a, b) - h * h * smoothing / 4
      }
    }
  }

  private struct LabelCut: Codable {
    let axis: String
    let normalizedPosition: Double
    let boundary: String
    let negativeRegion: String
    let positiveRegion: String
    let confidence: Double
  }

  private struct LabelPlan: Codable {
    let summary: String
    let cuts: [LabelCut]
  }

  private struct Message: Codable {
    let role: String
    let content: String
  }

  /// The layout `mlx_vlm.train` reads: image paths are top-level and relative to the dataset folder.
  private struct Row: Codable {
    let messages: [Message]
    let images: [String]
  }

  public struct Summary: Sendable {
    public let written: Int
    public let skipped: Int
  }

  private struct Manifest: Encodable {
    let schemaVersion = 1
    let task = "anatomy-cuts"
    let seed: UInt64
    let requested: Int
    let written: Int
    let skipped: Int
    let resolution: Int
    let train: Int
    let validation: Int
    let test: Int
  }

  public static func generate(count: Int, seed: UInt64, outputDirectory: URL, resolution: Int = 56)
    throws -> Summary
  {
    guard count > 0, resolution >= 24, resolution <= 128 else {
      throw PlushAgentError.unreadable("count must be positive and resolution within 24...128")
    }
    let fm = FileManager.default
    guard !fm.fileExists(atPath: outputDirectory.appendingPathComponent("train.jsonl").path),
      !fm.fileExists(atPath: outputDirectory.appendingPathComponent("valid.jsonl").path),
      !fm.fileExists(atPath: outputDirectory.appendingPathComponent("test.jsonl").path)
    else {
      throw PlushAgentError.unreadable(
        "dataset output already contains split files; choose a new versioned directory")
    }
    try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    var rng = SplitMix64(state: seed)
    var rows: [Data] = []
    var skipped = 0
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    for index in 0..<count {
      let creature = makeCreature(&rng)
      guard let example = try? build(creature, rng: &rng, resolution: resolution) else {
        skipped += 1
        continue
      }
      let name = String(format: "creature_%04d", index)
      let directory = outputDirectory.appendingPathComponent(name, isDirectory: true)
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
      let views = try AnatomyMeshViewRenderer.render(
        positions: example.positions, triangles: example.triangles)
      var imagePaths: [String] = []
      for (view, data) in zip(AnatomyMeshViewRenderer.View.allCases, views) {
        let file = "\(name)/\(view.rawValue).png"
        try data.write(to: outputDirectory.appendingPathComponent(file))
        imagePaths.append(file)
      }
      let label = String(decoding: try encoder.encode(example.plan), as: UTF8.self)
      let row = Row(
        messages: [
          Message(role: "user", content: OnDeviceSeamAdvisor.anatomyPrompt),
          Message(role: "assistant", content: label),
        ], images: imagePaths)
      rows.append(try encoder.encode(row))
      try label.write(
        to: directory.appendingPathComponent("label.json"), atomically: true, encoding: .utf8)
    }

    // Keep each independently generated source geometry in exactly one split.
    let test = rows.enumerated().filter { $0.offset % 10 == 0 }.map(\.element)
    let valid = rows.enumerated().filter { $0.offset % 10 == 9 }.map(\.element)
    let train = rows.enumerated().filter { $0.offset % 10 != 0 && $0.offset % 10 != 9 }.map(
      \.element)
    guard !train.isEmpty, !valid.isEmpty, !test.isEmpty else {
      throw PlushAgentError.unreadable(
        "generation produced too few usable examples for train/validation/test splits")
    }
    try write(lines: train, to: outputDirectory.appendingPathComponent("train.jsonl"))
    try write(lines: valid, to: outputDirectory.appendingPathComponent("valid.jsonl"))
    try write(lines: test, to: outputDirectory.appendingPathComponent("test.jsonl"))
    let manifest = Manifest(
      seed: seed,
      requested: count,
      written: rows.count,
      skipped: skipped,
      resolution: resolution,
      train: train.count,
      validation: valid.count,
      test: test.count
    )
    let manifestData = try JSONEncoder().encode(manifest)
    try manifestData.write(
      to: outputDirectory.appendingPathComponent("manifest.json"), options: .atomic)
    return Summary(written: rows.count, skipped: skipped)
  }

  private static func write(lines: [Data], to url: URL) throws {
    var data = Data()
    for line in lines {
      data.append(line)
      data.append(0x0A)
    }
    try data.write(to: url)
  }

  private static func uniform(_ range: ClosedRange<Double>, _ rng: inout SplitMix64) -> Double {
    Double.random(in: range, using: &rng)
  }

  private static func makeCreature(_ rng: inout SplitMix64) -> Creature {
    let morphology = Int.random(in: 0..<6, using: &rng)
    let rx: Double
    let ry: Double
    let rz: Double
    switch morphology {
    case 0:
      rx = uniform(0.55...0.9, &rng)
      ry = uniform(0.95...1.35, &rng)
      rz = uniform(0.5...0.8, &rng)
    case 1:
      rx = uniform(0.55...0.85, &rng)
      ry = uniform(0.55...0.9, &rng)
      rz = uniform(1.0...1.45, &rng)
    case 2:
      rx = uniform(0.4...0.7, &rng)
      ry = uniform(0.45...0.75, &rng)
      rz = uniform(1.2...1.65, &rng)
    case 3:
      rx = uniform(0.8...1.2, &rng)
      ry = uniform(0.7...1.0, &rng)
      rz = uniform(0.8...1.2, &rng)
    case 4:
      rx = uniform(0.8...1.2, &rng)
      ry = uniform(0.45...0.75, &rng)
      rz = uniform(0.75...1.1, &rng)
    default:
      rx = uniform(0.6...1.1, &rng)
      ry = uniform(0.7...1.2, &rng)
      rz = uniform(0.6...0.95, &rng)
    }
    let torso = Part(name: "torso", center: .zero, radii: Vec3(rx, ry, rz))
    var parts: [Part] = []
    func pair(_ prefix: String, parent: String = "torso", _ make: (Double, String) -> Part) {
      for (side, sign) in [("left", 1.0), ("right", -1.0)] {
        var part = make(sign, "\(prefix)\(side) ")
        part.parent = parent
        parts.append(part)
      }
    }

    let quadruped = morphology == 1 || morphology == 2 || morphology == 4
    let forward = quadruped ? Vec3(0, 0, 1) : Vec3(0, 1, 0)
    let hasHead = Int.random(in: 0..<12, using: &rng) != 0
    var headCenter = quadruped ? Vec3(0, ry * 0.55, rz) : Vec3(0, ry, 0)
    var head = 0.0
    if hasHead {
      head = uniform(0.35...0.95, &rng)
      if quadruped {
        headCenter = Vec3(
          uniform(-0.12...0.12, &rng),
          ry * uniform(0.35...0.8, &rng),
          rz + head * uniform(0.45...0.8, &rng)
        )
        parts.append(
          Part(
            name: "head",
            center: headCenter,
            radii: Vec3(head * uniform(0.8...1.1, &rng), head * 0.8, head)
          ))
      } else {
        headCenter = Vec3(0, ry + head * uniform(0.55...0.85, &rng), uniform(-0.1...0.15, &rng))
        parts.append(
          Part(
            name: "head",
            center: headCenter,
            radii: Vec3(head, head * uniform(0.75...1.05, &rng), head * uniform(0.75...1.1, &rng))
          ))
      }
    }

    switch Int.random(in: 0..<7, using: &rng) {
    case 0:
      let span = uniform(0.4...0.95, &rng)
      let y = uniform(-0.3...0.45, &rng)
      let z = uniform(-0.2...0.15, &rng)
      pair(
        "",
        { sign, p in
          Part(
            name: p + "wing", center: Vec3(sign * (rx + span * 0.8), y, z),
            radii: Vec3(span, uniform(0.18...0.4, &rng), 0.16))
        })
    case 1:
      let reach = uniform(0.3...0.55, &rng)
      let y = uniform(-0.2...0.4, &rng)
      let w = uniform(0.2...0.32, &rng)
      pair(
        "",
        { sign, p in
          Part(
            name: p + "arm", center: Vec3(sign * (rx + reach * 0.8), y, 0.1),
            radii: Vec3(reach, w, w))
        })
    case 2:
      let span = uniform(0.4...0.8, &rng)
      let reach = uniform(0.3...0.45, &rng)
      pair(
        "",
        { sign, p in
          Part(
            name: p + "wing", center: Vec3(sign * (rx + span * 0.8), 0.55, -0.15),
            radii: Vec3(span, 0.3, 0.15))
        })
      pair(
        "",
        { sign, p in
          Part(
            name: p + "arm", center: Vec3(sign * (rx + reach * 0.8), -0.25, 0.15),
            radii: Vec3(reach, 0.25, 0.25))
        })
    case 3:
      let span = uniform(0.35...0.8, &rng)
      pair(
        "",
        { sign, p in
          Part(
            name: p + "fin", center: Vec3(sign * (rx + span * 0.7), 0, 0),
            radii: Vec3(span, 0.12, uniform(0.18...0.35, &rng)))
        })
    case 4:
      let reach = uniform(0.4...0.75, &rng)
      let width = uniform(0.12...0.25, &rng)
      let tentacleCount = Int.random(in: 2...4, using: &rng)
      for index in 0..<tentacleCount {
        let side = index.isMultiple(of: 2) ? 1.0 : -1.0
        let row = index / 2
        parts.append(
          Part(
            name: "tentacle \(index + 1)",
            center: Vec3(
              side * (rx + reach * 0.55), -Double(row) * width, uniform(-0.35...0.35, &rng)),
            radii: Vec3(reach, width, width)
          ))
      }
    case 5:
      let reach = uniform(0.35...0.65, &rng)
      let width = uniform(0.18...0.3, &rng)
      pair(
        "",
        { sign, p in
          Part(
            name: p + "flipper", center: Vec3(sign * (rx + reach * 0.7), -ry * 0.2, rz * 0.25),
            radii: Vec3(reach, width, width * 1.7))
        })
    default:
      break
    }

    switch Int.random(in: 0..<12, using: &rng) {
    case 0..<5:
      let leg = uniform(0.22...0.42, &rng)
      if quadruped {
        for (zName, zSign) in [("front", 1.0), ("back", -1.0)] {
          pair(
            "\(zName) ",
            { sign, p in
              Part(
                name: p + "leg",
                center: Vec3(sign * rx * 0.65, -ry * 0.45, zSign * rz * 0.6),
                radii: Vec3(leg, leg * uniform(0.9...1.3, &rng), leg)
              )
            })
        }
      } else {
        pair(
          "",
          { sign, p in
            Part(
              name: p + "leg",
              center: Vec3(sign * rx * 0.5, -ry - leg * 0.8, 0.1),
              radii: Vec3(leg, leg * uniform(0.9...1.3, &rng), leg)
            )
          })
      }
    case 5..<8:
      let leg = uniform(0.24...0.36, &rng)
      for (zName, zSign) in [("front", 1.0), ("back", -1.0)] {
        pair(
          "\(zName) ",
          { sign, p in
            Part(
              name: p + "leg",
              center: Vec3(sign * rx * 0.55, -ry - leg * 0.7, zSign * rz * 0.6),
              radii: Vec3(leg, leg * 1.2, leg)
            )
          })
      }
    default:
      break
    }

    if Int.random(in: 0..<10, using: &rng) < 5 {
      let tail = uniform(0.2...0.34, &rng)
      let length = uniform(1.2...2.2, &rng)
      let direction = quadruped ? -1.0 : (Bool.random(using: &rng) ? -1.0 : 1.0)
      let center =
        quadruped
        ? Vec3(0, ry * uniform(0.2...0.6, &rng), direction * (rz + tail * length))
        : Vec3(0, uniform(-0.5...0.1, &rng), direction * (rz + tail * length))
      parts.append(Part(name: "tail", center: center, radii: Vec3(tail, tail, tail * length)))
    }

    if hasHead {
      let roll = Int.random(in: 0..<10, using: &rng)
      if roll < 4 {
        let ear = head * uniform(0.25...0.45, &rng)
        pair(
          "", parent: "head",
          { sign, p in
            Part(
              name: p + "ear",
              center: headCenter + Vec3(sign * head * 0.6, head * 0.8, quadruped ? head * 0.2 : 0),
              radii: Vec3(ear * 0.6, ear * 1.5, ear * 0.5)
            )
          })
      } else if roll < 6 {
        let horn = head * uniform(0.18...0.3, &rng)
        let direction = quadruped ? forward : Vec3(0, 1, 0)
        var part = Part(
          name: "horn",
          center: headCenter + direction * (head + horn * 0.8),
          radii: Vec3(horn, horn * 1.6, horn)
        )
        part.parent = "head"
        parts.append(part)
      } else if roll < 7 {
        let snout = head * uniform(0.35...0.5, &rng)
        var part = Part(
          name: "snout",
          center: headCenter + forward * (head + snout * 0.45),
          radii: Vec3(snout * 0.8, snout * 0.65, snout * 1.1)
        )
        part.parent = "head"
        parts.append(part)
      } else if roll < 9 {
        let neck = head * uniform(0.2...0.38, &rng)
        var part = Part(
          name: "neck",
          center: headCenter - forward * (head * 0.75),
          radii: quadruped
            ? Vec3(neck, neck * 1.2, head)
            : Vec3(neck, head, neck)
        )
        part.parent = "torso"
        parts.append(part)
      }
    }
    return Creature(torso: torso, appendages: parts)
  }

  private static func build(
    _ creature: Creature,
    rng: inout SplitMix64,
    resolution n: Int
  ) throws -> (positions: [Vec3], triangles: [Int32], plan: LabelPlan) {
    let extent = 6.4
    let spacing = extent / Double(n - 1)
    let origin = Vec3(repeating: -extent / 2)
    var values = [Float](repeating: 0, count: n * n * n)
    for z in 0..<n {
      for y in 0..<n {
        for x in 0..<n {
          let p = origin + Vec3(Double(x), Double(y), Double(z)) * spacing
          values[x + n * (y + n * z)] = Float(-creature.field(p))
        }
      }
    }
    let field = try ScalarField(resolution: n, values: values, origin: origin, spacing: spacing)
    let mesh = try MarchingTetrahedra.extract(field)
    guard mesh.triangles.count > 200 else {
      throw PlushAgentError.unreadable("creature mesh too small")
    }
    guard OpenPieceSeams.boundaryLoops(triangles: mesh.topologyInput.triangles).isEmpty else {
      throw PlushAgentError.unreadable("creature mesh touches the grid border")
    }

    // Random signed axis permutation so the model is not always upright.
    var order = [0, 1, 2]
    order.shuffle(using: &rng)
    let signs = (0..<3).map { _ in Bool.random(using: &rng) ? 1.0 : -1.0 }
    func transform(_ p: Vec3) -> Vec3 {
      Vec3(p[order[0]] * signs[0], p[order[1]] * signs[1], p[order[2]] * signs[2])
    }
    let (rawPositions, triangles) = mesh.topologyInput
    var positions = rawPositions.map(transform)
    var flipped = false
    if signs[0] * signs[1] * signs[2] < 0 {
      // A reflection reverses winding; restore outward-facing triangles.
      flipped = true
    }
    var fixedTriangles = triangles
    if flipped {
      for t in stride(from: 0, to: fixedTriangles.count, by: 3) {
        fixedTriangles.swapAt(t + 1, t + 2)
      }
    }

    var lo = positions[0]
    var hi = positions[0]
    for p in positions {
      lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
      hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
    }
    let axes = ["x", "y", "z"]

    var cuts: [LabelCut] = []
    for part in creature.appendages {
      // The joint is where the two parts' surfaces are equidistant on the segment between their centers.
      let parent = creature.parts.first { $0.name == part.parent } ?? creature.torso
      let a = parent.center
      let b = part.center
      var low = 0.0
      var high = 1.0
      for _ in 0..<40 {
        let mid = (low + high) / 2
        let p = a + (b - a) * mid
        if parent.distance(p) < part.distance(p) { low = mid } else { high = mid }
      }
      let joint = a + (b - a) * ((low + high) / 2)
      let direction = transform(b - a)
      guard let axis = (0..<3).max(by: { abs(direction[$0]) < abs(direction[$1]) }) else {
        continue
      }
      let span = hi[axis] - lo[axis]
      let position = (transform(joint)[axis] - lo[axis]) / span
      guard (0.1...0.9).contains(position) else { continue }
      let partIsPositive = direction[axis] > 0
      cuts.append(
        LabelCut(
          axis: axes[axis],
          normalizedPosition: (position * 1000).rounded() / 1000,
          boundary: "\(part.name) joint",
          negativeRegion: partIsPositive ? parent.name : part.name,
          positiveRegion: partIsPositive ? part.name : parent.name,
          confidence: 0.9
        ))
    }
    let geometryCuts = try cuts.map { cut -> AnatomicalCut in
      guard let axis = AnatomicalAxis(rawValue: cut.axis) else {
        throw PlushAgentError.unreadable("generated cut has an invalid axis")
      }
      return AnatomicalCut(
        axis: axis,
        normalizedPosition: cut.normalizedPosition,
        boundary: cut.boundary,
        negativeRegion: cut.negativeRegion,
        positiveRegion: cut.positiveRegion,
        confidence: cut.confidence
      )
    }
    let mergedCuts = AnatomyCutPlanNormalizer.normalize(geometryCuts).map {
      LabelCut(
        axis: $0.axis.rawValue,
        normalizedPosition: $0.normalizedPosition,
        boundary: $0.boundary,
        negativeRegion: $0.negativeRegion,
        positiveRegion: $0.positiveRegion,
        confidence: $0.confidence
      )
    }
    // Keep generated plans within the splitter and advisor's supported cut limit.
    guard !mergedCuts.isEmpty, mergedCuts.count <= 8 else {
      throw PlushAgentError.unreadable("no usable joints")
    }
    let validatedCuts = mergedCuts.compactMap { cut -> AnatomicalCut? in
      guard let axis = AnatomicalAxis(rawValue: cut.axis) else { return nil }
      return AnatomicalCut(
        axis: axis,
        normalizedPosition: cut.normalizedPosition,
        boundary: cut.boundary,
        negativeRegion: cut.negativeRegion,
        positiveRegion: cut.positiveRegion,
        confidence: cut.confidence
      )
    }
    guard validatedCuts.count == mergedCuts.count else {
      throw PlushAgentError.unreadable("generated cut has an invalid axis")
    }
    _ = try AnatomicalMeshSplitter.split(
      positions: positions, triangles: fixedTriangles, cuts: validatedCuts)
    let names = mergedCuts.map { $0.boundary.replacingOccurrences(of: " joint", with: "") }.joined(
      separator: ", ")
    let plan = LabelPlan(
      summary: "Torso with \(mergedCuts.count) joined parts: \(names). Cut at each joint.",
      cuts: mergedCuts)
    positions = positions.map { $0 }
    return (positions, fixedTriangles, plan)
  }

}

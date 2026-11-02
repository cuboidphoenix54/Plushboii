import XCTest
@testable import TopologyKit

final class StressTests: XCTestCase {
    typealias Mesh = (positions: [Vec3], triangles: [Int32])

    private func uvSphere(rings: Int, segments: Int, scale: Vec3 = Vec3(1, 1, 1)) -> Mesh {
        var p: [Vec3] = [Vec3(0, scale.y, 0)]
        for r in 1..<rings {
            let phi = Double.pi * Double(r) / Double(rings)
            for s in 0..<segments {
                let th = 2 * Double.pi * Double(s) / Double(segments)
                p.append(Vec3(sin(phi) * cos(th) * scale.x, cos(phi) * scale.y, sin(phi) * sin(th) * scale.z))
            }
        }
        p.append(Vec3(0, -scale.y, 0))
        var t: [Int32] = []
        for s in 0..<segments { t += [0, Int32(1 + (s + 1) % segments), Int32(1 + s)] }
        for r in 0..<(rings - 2) { for s in 0..<segments {
            let a = Int32(1 + r * segments + s), b = Int32(1 + r * segments + (s + 1) % segments)
            let c = a + Int32(segments), d = b + Int32(segments)
            t += [a, b, c, b, d, c]
        } }
        let last = Int32(p.count - 1), base = Int32(1 + (rings - 2) * segments)
        for s in 0..<segments { t += [last, base + Int32(s), base + Int32((s + 1) % segments)] }
        return (p, t)
    }

    private func torus(major: Int, minor: Int, holes: Int = 1) -> Mesh {
        var p: [Vec3] = [], t: [Int32] = []
        for i in 0..<major { for j in 0..<minor {
            let u = 2 * Double.pi * Double(i) / Double(major), v = 2 * Double.pi * Double(j) / Double(minor)
            p.append(Vec3((2 + 0.6 * cos(v)) * cos(u), 0.6 * sin(v), (2 + 0.6 * cos(v)) * sin(u)))
        } }
        for i in 0..<major { for j in 0..<minor {
            let a = Int32(i * minor + j), b = Int32(((i + 1) % major) * minor + j)
            let c = Int32(i * minor + (j + 1) % minor), d = Int32(((i + 1) % major) * minor + (j + 1) % minor)
            t += [a, b, d, a, d, c]
        } }
        return (p, t)
    }

    private func cone(segments: Int, rings: Int, height: Double = 4) -> Mesh {
        var p: [Vec3] = []
        for r in 0..<rings { for s in 0..<segments {
            let y = Double(r) / Double(rings), a = 2 * Double.pi * Double(s) / Double(segments)
            p.append(Vec3((1 - y) * cos(a), y * height, (1 - y) * sin(a)))
        } }
        let apex = Int32(p.count); p.append(Vec3(0, height, 0))
        var t: [Int32] = []
        for r in 0..<(rings - 1) { for s in 0..<segments {
            let a = Int32(r * segments + s), b = Int32(r * segments + (s + 1) % segments)
            let c = a + Int32(segments), d = b + Int32(segments)
            t += [a, c, b, b, c, d]
        } }
        for s in 0..<segments { t += [apex, Int32((rings - 1) * segments + s), Int32((rings - 1) * segments + (s + 1) % segments)] }
        return (p, t)
    }

    private func disc(segments: Int) -> Mesh {
        var p: [Vec3] = [Vec3(0, 0, 0)], t: [Int32] = []
        for s in 0..<segments { let a = 2 * Double.pi * Double(s) / Double(segments); p.append(Vec3(cos(a), 0, sin(a))) }
        for s in 0..<segments { t += [0, Int32(1 + s), Int32(1 + (s + 1) % segments)] }
        return (p, t)
    }

    private func merged(_ meshes: [Mesh], offsets: [Vec3]) -> Mesh {
        var p: [Vec3] = [], t: [Int32] = []
        for (m, o) in zip(meshes, offsets) {
            let base = Int32(p.count)
            p += m.positions.map { $0 + o }
            t += m.triangles.map { $0 + base }
        }
        return (p, t)
    }

    private func obj(_ m: Mesh) -> String {
        var s = ""
        for p in m.positions { s += "v \(p.x) \(p.y) \(p.z)\n" }
        for i in stride(from: 0, to: m.triangles.count, by: 3) { s += "f \(m.triangles[i] + 1) \(m.triangles[i + 1] + 1) \(m.triangles[i + 2] + 1)\n" }
        return s
    }

    /// The agent must never crash or hang: it returns a report or throws a clear error.
    private func run(_ name: String, text: String, subject: SubjectOverride = .auto, file: StaticString = #filePath, line: UInt = #line) throws -> PlushAgentReport? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stress-\(name)-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        var options = PlushAgentOptions()
        options.subject = subject
        let start = Date()
        FileHandle.standardError.write(Data("[stress] \(name) \(subject)\n".utf8))
        do {
            let report = try PlushAgent.run(input: url, options: options)
            XCTAssertLessThan(Date().timeIntervalSince(start), 120, "\(name) was too slow", file: file, line: line)
            return report
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line)
            return nil
        }
    }

    func testShapeZoo() throws {
        let shapes: [(String, Mesh)] = [
            ("sphere", uvSphere(rings: 20, segments: 30)),
            ("needle", uvSphere(rings: 20, segments: 30, scale: Vec3(0.02, 5, 0.02))),
            ("pancake", uvSphere(rings: 20, segments: 30, scale: Vec3(4, 0.05, 4))),
            ("cone", cone(segments: 24, rings: 10)),
            ("squat-cone", cone(segments: 24, rings: 10, height: 0.5)),
            ("torus", torus(major: 24, minor: 12)),
            ("disc", disc(segments: 40)),
            ("tiny", uvSphere(rings: 12, segments: 16, scale: Vec3(1e-6, 1e-6, 1e-6))),
            ("huge", uvSphere(rings: 12, segments: 16, scale: Vec3(1e6, 1e6, 1e6))),
            ("two-spheres", merged([uvSphere(rings: 12, segments: 16), uvSphere(rings: 12, segments: 16)], offsets: [Vec3(0, 0, 0), Vec3(5, 0, 0)])),
            ("two-tori", merged([torus(major: 16, minor: 8), torus(major: 16, minor: 8)], offsets: [Vec3(0, 0, 0), Vec3(0, 3, 0)])),
        ]
        for (name, mesh) in shapes {
            let report = try run(name, text: obj(mesh))
            if let report { XCTAssertFalse(report.verdict.isEmpty, name); XCTAssertFalse(report.subjectKind.isEmpty, name) }
        }
    }

    func testHostileInputsNeverCrash() throws {
        let sphere = uvSphere(rings: 10, segments: 12)
        var inverted = sphere; inverted.triangles = stride(from: 0, to: sphere.triangles.count, by: 3).flatMap { [sphere.triangles[$0], sphere.triangles[$0 + 2], sphere.triangles[$0 + 1]] }
        var duplicated = sphere; duplicated.triangles += sphere.triangles
        var degenerate = sphere; degenerate.triangles += [0, 0, 1, 2, 2, 2]
        var nonManifold = sphere; nonManifold.positions.append(Vec3(0, 0, 3)); nonManifold.triangles += [0, 1, Int32(sphere.positions.count), 0, 1, Int32(sphere.positions.count)]
        let cases: [(String, String)] = [
            ("empty", ""), ("garbage", "hello world\nv a b c\nf x y z"), ("no-faces", "v 0 0 0\nv 1 0 0\nv 0 1 0\n"),
            ("one-tri", "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n"), ("oob-index", "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 9\n"),
            ("nan", "v nan 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n"), ("inf", "v inf 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n"),
            ("negative-index", "v 0 0 0\nv 1 0 0\nv 0 1 0\nf -1 -2 -3\n"), ("quads", "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n"),
            ("inverted", obj(inverted)), ("duplicated", obj(duplicated)), ("degenerate", obj(degenerate)), ("non-manifold", obj(nonManifold)),
            ("collinear", "v 0 0 0\nv 1 0 0\nv 2 0 0\nf 1 2 3\n"), ("coincident", "v 1 1 1\nv 1 1 1\nv 1 1 1\nf 1 2 3\n"),
        ]
        for (name, text) in cases {
            for subject in [SubjectOverride.auto, .object, .creature] { _ = try run(name, text: text, subject: subject) }
        }
    }

    func testLargeMeshStaysWithinTimeBudget() throws {
        let report = try run("large", text: obj(uvSphere(rings: 200, segments: 300)))
        XCTAssertNotNil(report)
        XCTAssertLessThanOrEqual(report?.finalFaces ?? 0, 25_000)
    }

    func testRepeatedRunsAreDeterministic() throws {
        let text = obj(torus(major: 20, minor: 10))
        let a = try run("det-a", text: text), b = try run("det-b", text: text)
        XCTAssertEqual(a?.verdict, b?.verdict)
        XCTAssertEqual(a?.pieces.count, b?.pieces.count)
        XCTAssertEqual(a?.pieces.map(\.panelCount), b?.pieces.map(\.panelCount))
    }

    func testClassifierAndSplittersHandleDegenerateGeometry() throws {
        for positions in [[Vec3](), [Vec3(0, 0, 0)], [Vec3](repeating: Vec3(1, 1, 1), count: 30), [Vec3(.nan, 0, 0), Vec3(0, 1, 0)]] {
            let a = SubjectClassifier.classify(positions: positions, triangles: [], joints: [], mirrorMatch: nil)
            XCTAssertTrue(a.creatureScore.isFinite)
            _ = SubjectClassifier.taperProfile(positions: positions)
            _ = try? SubjectClassifier.slabComponents(positions: positions, triangles: [], count: 4)
        }
        XCTAssertEqual(HandleSeams.genus(triangles: []), 0)
        XCTAssertTrue(HandleSeams.seams(positions: [], triangles: []).isEmpty)
    }

    func testMultiHandleGenusIsCutIntoDisc() throws {
        let m = merged([torus(major: 16, minor: 8)], offsets: [Vec3(0, 0, 0)])
        let seams = HandleSeams.seams(positions: m.positions, triangles: m.triangles)
        XCTAssertFalse(seams.isEmpty)
        XCTAssertNoThrow(try TopologyEngine.flatten(positions: m.positions, triangles: m.triangles, seams: seams, fabric: .none, tolerance: 100, refine: false))
    }

    func testConstructionNotesDescribeHollowPoseFreeShell() {
        let parts = [MeshComponent(id: 0, positions: [], triangles: [], sourceVertices: [], anatomicalLabel: "torso"),
                     MeshComponent(id: 1, positions: [], triangles: [], sourceVertices: [], anatomicalLabel: "left arm")]
        let creature = PlushAgent.constructionNotes(kind: .creature, components: parts)
        XCTAssertTrue(creature.contains { $0.contains("Teddy-bear") && $0.contains("1 attachment") })
        XCTAssertTrue(creature.contains { $0.contains("Hollow") })
        XCTAssertFalse(PlushAgent.constructionNotes(kind: .object, components: parts).contains { $0.contains("Teddy-bear") })
    }
}

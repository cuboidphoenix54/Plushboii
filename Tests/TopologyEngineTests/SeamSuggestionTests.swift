import XCTest
@testable import TopologyKit

final class SeamSuggestionTests: XCTestCase {
    func testSuggestionsAreVerifiedMultiSeamPanelLayouts() throws {
        let (positions, triangles) = curvedGrid()
        let suggestions = try SeamSuggestionEngine.suggest(positions: positions, triangles: triangles)
        let edges = Set((0..<(triangles.count / 3)).flatMap { face in
            (0..<3).map { corner in
                let a = Int(triangles[face * 3 + corner])
                let b = Int(triangles[face * 3 + (corner + 1) % 3])
                return "\(min(a, b))-\(max(a, b))"
            }
        })

        XCTAssertFalse(suggestions.isEmpty)
        XCTAssertLessThanOrEqual(suggestions.count, 3)
        XCTAssertEqual(Set(suggestions.map(\.id)).count, suggestions.count)
        for suggestion in suggestions {
            XCTAssertFalse(suggestion.seamPaths.isEmpty)
            XCTAssertTrue(suggestion.seamPaths.allSatisfy { path in
                path.count >= 2 && zip(path, path.dropFirst()).allSatisfy {
                    edges.contains("\(min($0, $1))-\(max($0, $1))")
                }
            })
            let flattened = try TopologyEngine.flatten(
                positions: positions,
                triangles: triangles,
                seams: suggestion.seamPaths
            )
            XCTAssertEqual(flattened.islands.count, suggestion.panelCount)
            XCTAssertTrue(flattened.islands.allSatisfy(\.report.passed))
            let stitchLengths = boundaryEdgeLengths(in: flattened)
            let cutEdges = Set(suggestion.seamPaths.flatMap { path in
                zip(path, path.dropFirst()).map {
                    SurfaceCutter.edgeKey(Int32($0), Int32($1))
                }
            })
            for edge in cutEdges {
                XCTAssertEqual(stitchLengths[edge]?.count, 2, "\(suggestion.id) cut edge \(edge) must have two stitch-line copies.")
            }
            let actualMismatch = suggestion.id.hasPrefix("open-")
                ? OpenPieceSeams.stitchMismatch(islands: flattened.islands, seams: suggestion.seamPaths)
                : cutEdges.compactMap { edge -> Double? in
                guard let lengths = stitchLengths[edge], lengths.count == 2 else { return nil }
                return abs(lengths[0] - lengths[1]) / ((lengths[0] + lengths[1]) * 0.5)
            }.max() ?? 0
            XCTAssertEqual(actualMismatch, suggestion.worstStitchLengthMismatch, accuracy: 1e-10)
            XCTAssertEqual(
                flattened.islands.map(\.geometryReport.areaDelta).max() ?? 0,
                suggestion.worstAreaDelta,
                accuracy: 1e-10
            )
        }
        XCTAssertTrue(zip(suggestions, suggestions.dropFirst()).allSatisfy { $0.layoutScore <= $1.layoutScore })
    }

    func testUniformScalePreservesTheSuggestedLayoutAndNormalizedMetrics() throws {
        let (positions, triangles) = curvedGrid()
        let original = try SeamSuggestionEngine.suggest(positions: positions, triangles: triangles)
        let scaled = try SeamSuggestionEngine.suggest(
            positions: positions.map { $0 * 1e-8 },
            triangles: triangles
        )

        XCTAssertEqual(original.map(\.id), scaled.map(\.id))
        for (lhs, rhs) in zip(original, scaled) {
            XCTAssertEqual(lhs.seamPaths, rhs.seamPaths)
            XCTAssertEqual(lhs.panelCount, rhs.panelCount)
            XCTAssertEqual(lhs.worstAreaDelta, rhs.worstAreaDelta, accuracy: 1e-7)
            XCTAssertEqual(lhs.worstStitchLengthMismatch, rhs.worstStitchLengthMismatch, accuracy: 1e-7)
            XCTAssertEqual(lhs.largestPanelAreaShare, rhs.largestPanelAreaShare, accuracy: 1e-7)
            XCTAssertEqual(lhs.normalizedSeamLength, rhs.normalizedSeamLength, accuracy: 1e-7)
            XCTAssertEqual(lhs.layoutScore, rhs.layoutScore, accuracy: 1e-7)
        }
    }

    func testInvalidMeshDoesNotProduceSuggestedCuts() {
        XCTAssertThrowsError(
            try SeamSuggestionEngine.suggest(
                positions: [Vec3.zero, Vec3(1, 0, 0), Vec3(0, 1, 0)],
                triangles: [0, 0, 2]
            )
        )
    }

    func testDegenerateAndNonFiniteGeometryAreRejected() {
        XCTAssertThrowsError(
            try SeamSuggestionEngine.suggest(
                positions: [Vec3.zero, Vec3(1, 0, 0), Vec3(2, 0, 0)],
                triangles: [0, 1, 2]
            )
        )
        XCTAssertThrowsError(
            try SeamSuggestionEngine.suggest(
                positions: [Vec3.zero, Vec3(1, 0, 0), Vec3(0, .nan, 1)],
                triangles: [0, 1, 2]
            )
        )
    }

    func testNonManifoldEdgesAreRejectedBeforePathSearch() {
        let positions = [
            Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, -1, 0), Vec3(0, 0, 1),
        ]
        let triangles: [Int32] = [
            0, 1, 2,
            1, 0, 3,
            0, 1, 4,
        ]
        XCTAssertThrowsError(try SeamSuggestionEngine.suggest(positions: positions, triangles: triangles))
    }

    private func curvedGrid() -> ([Vec3], [Int32]) {
        let n = 8
        var positions: [Vec3] = []
        for j in 0...n {
            for i in 0...n {
                let u = (Double(i) / Double(n) - 0.5) * Double.pi * 0.9
                let v = (Double(j) / Double(n) - 0.5) * Double.pi * 0.9
                positions.append(Vec3(sin(u) * cos(v), sin(v), cos(u) * cos(v)))
            }
        }
        var triangles: [Int32] = []
        for j in 0..<n {
            for i in 0..<n {
                let a = Int32(j * (n + 1) + i)
                let b = a + 1
                let c = a + Int32(n + 1)
                let d = c + 1
                triangles += [a, b, d, a, d, c]
            }
        }
        return (positions, triangles)
    }

    private func boundaryEdgeLengths(in result: FlatteningResult) -> [UInt64: [Double]] {
        var lengths: [UInt64: [Double]] = [:]
        for island in result.islands {
            var edgeCounts: [UInt64: Int] = [:]
            for corner in stride(from: 0, to: island.triangles.count, by: 3) {
                for index in 0..<3 {
                    let a = Int(island.triangles[corner + index])
                    let b = Int(island.triangles[corner + (index + 1) % 3])
                    edgeCounts[SurfaceCutter.edgeKey(Int32(a), Int32(b)), default: 0] += 1
                }
            }
            for (edge, count) in edgeCounts where count == 1 {
                let a = Int(edge >> 32)
                let b = Int(edge & 0xFFFF_FFFF)
                let sourceEdge = SurfaceCutter.edgeKey(
                    Int32(island.sourceVertex[a]),
                    Int32(island.sourceVertex[b])
                )
                lengths[sourceEdge, default: []].append(vlength(island.uv[a] - island.uv[b]))
            }
        }
        return lengths
    }
}

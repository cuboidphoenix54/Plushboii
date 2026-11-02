import XCTest
@testable import TopologyKit

final class PatternDomainTests: XCTestCase {
    func testDomainValuesHaveStableNamesAndContexts() {
        XCTAssertEqual(PatternDomain.allCases.map(\.rawValue), ["plushie", "dogApparel", "humanApparel"])
        XCTAssertTrue(PatternDomain.plushie.rankingContext.contains("stuffed plushie"))
        XCTAssertTrue(PatternDomain.plushie.rankingContext.contains("head, torso, and"))
        XCTAssertTrue(PatternDomain.plushie.rankingContext.contains("Eyes, nose, and mouth"))
        XCTAssertTrue(PatternDomain.plushie.rankingContext.contains("do not establish which anatomical"))
        XCTAssertTrue(PatternDomain.dogApparel.rankingContext.contains("mobility"))
        XCTAssertTrue(PatternDomain.humanApparel.rankingContext.contains("grainline"))
    }

    func testTrainingExampleEncodesFeaturesAndPreferenceOrder() throws {
        let candidates = [suggestion(id: "layout-a", areaDelta: 0.01), suggestion(id: "layout-b", areaDelta: 0.02)]
        let example = try PatternRankingTrainingExample(
            domain: .dogApparel,
            vertexCount: 20,
            faceCount: 30,
            candidates: candidates,
            preferredCandidateIDs: ["layout-b", "layout-a"]
        )

        let decoded = try JSONDecoder().decode(
            PatternRankingTrainingExample.self,
            from: JSONEncoder().encode(example)
        )
        XCTAssertEqual(decoded, example)
        XCTAssertEqual(decoded.schemaVersion, PatternRankingTrainingExample.currentSchemaVersion)
        XCTAssertEqual(decoded.candidates.map(\.id), ["layout-a", "layout-b"])
        XCTAssertEqual(decoded.candidates.map(\.worstStitchLengthMismatch), [0.03, 0.03])
        XCTAssertEqual(decoded.preferredCandidateIDs, ["layout-b", "layout-a"])
    }

    func testOlderTrainingFeaturesDecodeWithoutStitchMismatch() throws {
        let example = try PatternRankingTrainingExample(
            domain: .plushie,
            vertexCount: 20,
            faceCount: 30,
            candidates: [suggestion(id: "layout-a", areaDelta: 0.01)],
            preferredCandidateIDs: ["layout-a"]
        )
        let encoded = try JSONEncoder().encode(example)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var candidates = try XCTUnwrap(object["candidates"] as? [[String: Any]])
        candidates[0].removeValue(forKey: "worstStitchLengthMismatch")
        object["candidates"] = candidates

        let decoded = try JSONDecoder().decode(
            PatternRankingTrainingExample.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(decoded.candidates[0].worstStitchLengthMismatch)
    }

    func testTrainingCorpusRoundTripsAsJSONLines() throws {
        let example = try PatternRankingTrainingExample(
            domain: .humanApparel,
            vertexCount: 20,
            faceCount: 30,
            candidates: [suggestion(id: "layout-a", areaDelta: 0.01)],
            preferredCandidateIDs: ["layout-a"]
        )

        let data = try PatternRankingTrainingCorpus.encodeJSONLines([example, example])
        XCTAssertEqual(try PatternRankingTrainingCorpus.decodeJSONLines(data), [example, example])
        XCTAssertThrowsError(try PatternRankingTrainingCorpus.encodeJSONLines([])) {
            XCTAssertEqual($0 as? PatternRankingTrainingDataError, .emptyDataset)
        }
    }

    func testTrainingExampleRejectsIncompleteOrInvalidLabels() {
        let candidates = [suggestion(id: "layout-a", areaDelta: 0.01), suggestion(id: "layout-b", areaDelta: 0.02)]
        XCTAssertThrowsError(
            try PatternRankingTrainingExample(
                domain: .plushie,
                vertexCount: 20,
                faceCount: 30,
                candidates: candidates,
                preferredCandidateIDs: ["layout-a"]
            )
        ) { XCTAssertEqual($0 as? PatternRankingTrainingDataError, .invalidPreferenceOrder) }

        XCTAssertThrowsError(
            try PatternRankingTrainingExample(
                domain: .plushie,
                vertexCount: 2,
                faceCount: 30,
                candidates: candidates,
                preferredCandidateIDs: ["layout-a", "layout-b"]
            )
        ) { XCTAssertEqual($0 as? PatternRankingTrainingDataError, .invalidMeshStatistics) }
    }

    private func suggestion(id: String, areaDelta: Double) -> SeamSuggestion {
        SeamSuggestion(
            id: id,
            title: "1 seam → 2 panels",
            seamPaths: [[0, 1]],
            panelCount: 2,
            worstAreaDelta: areaDelta,
            worstMeanLocalDistortion: 0.02,
            worstStitchLengthMismatch: 0.03,
            largestPanelAreaShare: 0.6,
            normalizedSeamLength: 1.2,
            dartCount: 0,
            layoutScore: 0.1,
            rationale: "Verified."
        )
    }
}

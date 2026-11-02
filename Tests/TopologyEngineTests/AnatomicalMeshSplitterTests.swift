import XCTest
import ImageIO
@testable import TopologyKit

final class AnatomicalMeshSplitterTests: XCTestCase {
    func testAnatomySchemaRequiresRegisteredPlaneAndRegionLabels() throws {
        let encoded = try JSONEncoder().encode(AnatomyJSONSchema())
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let cuts = try XCTUnwrap(properties["cuts"] as? [String: Any])
        let item = try XCTUnwrap(cuts["items"] as? [String: Any])
        let cutProperties = try XCTUnwrap(item["properties"] as? [String: Any])
        let axis = try XCTUnwrap(cutProperties["axis"] as? [String: Any])
        let required = try XCTUnwrap(item["required"] as? [String])

        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(item["type"] as? String, "object")
        XCTAssertEqual(cuts["type"] as? String, "array")
        XCTAssertEqual(cuts["maxItems"] as? Int, 9)
        XCTAssertEqual(axis["enum"] as? [String], ["x", "y", "z"])
        XCTAssertTrue(required.contains("negativeRegion"))
        XCTAssertTrue(required.contains("positiveRegion"))
        XCTAssertNotNil(cutProperties["normalizedPosition"])
        XCTAssertEqual(item["additionalProperties"] as? Bool, false)
    }

    func testNearCoincidentAnatomyPlanesMergeAndRetainBothLabels() throws {
        let normalized = AnatomyCutPlanNormalizer.normalize([
            AnatomicalCut(
                axis: .x,
                normalizedPosition: 0.31,
                boundary: "left leg joint",
                negativeRegion: "torso",
                positiveRegion: "left leg",
                confidence: 0.9
            ),
            AnatomicalCut(
                axis: .x,
                normalizedPosition: 0.32,
                boundary: "right leg joint",
                negativeRegion: "torso",
                positiveRegion: "right leg",
                confidence: 0.8
            ),
            AnatomicalCut(
                axis: .z,
                normalizedPosition: 0.6,
                boundary: "head joint",
                negativeRegion: "torso",
                positiveRegion: "head",
                confidence: 0.9
            ),
        ])

        XCTAssertEqual(normalized.count, 2)
        let legs = try XCTUnwrap(normalized.first { $0.axis == .x })
        XCTAssertEqual(legs.normalizedPosition, 0.315, accuracy: 1e-12)
        XCTAssertEqual(legs.boundary, "left leg joint / right leg joint")
        XCTAssertEqual(legs.negativeRegion, "torso")
        XCTAssertEqual(legs.positiveRegion, "left leg / right leg")
        XCTAssertEqual(legs.confidence, 0.8)
    }

    func testRegisteredOrthographicViewsRenderValidImages() throws {
        let images = try AnatomyMeshViewRenderer.render(
            positions: cubeVertices,
            triangles: cubeTriangles
        )

        XCTAssertEqual(images.count, 3)
        XCTAssertTrue(images.allSatisfy { data in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                return false
            }
            return image.width == 256 && image.height == 256
        })
    }

    func testAxisCutSplitsClosedCubeAndConservesSurfaceArea() throws {
        let positions = cubeVertices
        let triangles = cubeTriangles
        let sourceArea = try area(positions, triangles)
        let components = try AnatomicalMeshSplitter.split(
            positions: positions,
            triangles: triangles,
            cuts: [
                AnatomicalCut(
                    axis: .x,
                    normalizedPosition: 0.5,
                    boundary: "head / torso",
                    negativeRegion: "torso",
                    positiveRegion: "head",
                    confidence: 0.9
                )
            ]
        )

        XCTAssertEqual(components.count, 2)
        XCTAssertEqual(components.reduce(0) { $0 + $1.surfaceArea }, sourceArea, accuracy: sourceArea * 1e-8)
        XCTAssertTrue(components.flatMap(\.sourceVertices).contains(-1))
        XCTAssertTrue(components.flatMap(\.sourceVertices).allSatisfy { $0 == -1 || positions.indices.contains($0) })
        XCTAssertTrue(components.allSatisfy { component in
            component.triangles.allSatisfy { $0 >= 0 && Int($0) < component.positions.count }
        })
        XCTAssertTrue(components.flatMap(\.positions).contains { abs($0.x) < 1e-12 })
    }

    func testMultipleCutsCreateConnectedSurfacePieces() throws {
        let components = try AnatomicalMeshSplitter.split(
            positions: cubeVertices,
            triangles: cubeTriangles,
            cuts: [
                AnatomicalCut(
                    axis: .x,
                    normalizedPosition: 0.35,
                    boundary: "left appendage / torso",
                    negativeRegion: "left appendage",
                    positiveRegion: "torso",
                    confidence: 0.8
                ),
                AnatomicalCut(
                    axis: .x,
                    normalizedPosition: 0.65,
                    boundary: "torso / right appendage",
                    negativeRegion: "torso",
                    positiveRegion: "right appendage",
                    confidence: 0.8
                ),
            ]
        )

        XCTAssertEqual(components.count, 3)
        XCTAssertEqual(Set(components.compactMap(\.anatomicalLabel)), ["left appendage", "torso", "right appendage"])
        XCTAssertEqual(
            components.reduce(0) { $0 + $1.surfaceArea },
            try area(cubeVertices, cubeTriangles),
            accuracy: 1e-8
        )
    }

    func testCutOutsideMeshDoesNotSilentlyReturnUnchangedGeometry() {
        let cut = AnatomicalCut(
            axis: .y,
            normalizedPosition: 1,
            boundary: "head / torso",
            negativeRegion: "torso",
            positiveRegion: "head",
            confidence: 0.9
        )
        XCTAssertThrowsError(
            try AnatomicalMeshSplitter.split(positions: cubeVertices, triangles: cubeTriangles, cuts: [cut])
        )
    }

    func testNonSeparatingCutIsRejected() {
        let plane = AnatomicalCut(
            axis: .z,
            normalizedPosition: 0.5,
            boundary: "split",
            negativeRegion: "left",
            positiveRegion: "right",
            confidence: 0.9
        )
        XCTAssertThrowsError(
            try AnatomicalMeshSplitter.split(
                positions: [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)],
                triangles: [0, 1, 2],
                cuts: [plane]
            )
        )
    }

    private var cubeVertices: [Vec3] {
        [
            Vec3(-1, -1, -1), Vec3(1, -1, -1), Vec3(1, 1, -1), Vec3(-1, 1, -1),
            Vec3(-1, -1, 1), Vec3(1, -1, 1), Vec3(1, 1, 1), Vec3(-1, 1, 1),
        ]
    }

    private var cubeTriangles: [Int32] {
        [
            0, 2, 1, 0, 3, 2,
            4, 5, 6, 4, 6, 7,
            0, 1, 5, 0, 5, 4,
            1, 2, 6, 1, 6, 5,
            2, 3, 7, 2, 7, 6,
            3, 0, 4, 3, 4, 7,
        ]
    }

    private func area(_ positions: [Vec3], _ triangles: [Int32]) throws -> Double {
        var result = 0.0
        for offset in stride(from: 0, to: triangles.count, by: 3) {
            let a = positions[Int(triangles[offset])]
            let b = positions[Int(triangles[offset + 1])]
            let c = positions[Int(triangles[offset + 2])]
            result += 0.5 * vlength(vcross(b - a, c - a))
        }
        return result
    }
}

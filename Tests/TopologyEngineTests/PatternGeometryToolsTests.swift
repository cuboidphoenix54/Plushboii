import XCTest
@testable import TopologyKit

final class PatternGeometryToolsTests: XCTestCase {
    func testSphereGoreWidthIsEquatorCircumferenceOverGores() throws {
        let result = try PatternGeometryTool.sphereGores.run(["radius": 5, "gores": 6])
        XCTAssertTrue(result.text.contains("5.24"))
        XCTAssertTrue(result.text.contains("15.71"))
    }

    func testCylinderAddsAllowanceAfterCircumference() throws {
        let result = try PatternGeometryTool.cylinder.run(["diameter": 10, "height": 8, "seamAllowance": 1])
        XCTAssertTrue(result.text.contains("31.42"))
        XCTAssertTrue(result.text.contains("33.42 × 10.00"))
    }

    func testFrustumSlantVolumeAndSweep() throws {
        let result = try PatternGeometryTool.frustum.run(["bigRadius": 5, "smallRadius": 3, "height": 4])
        XCTAssertTrue(result.text.contains("Slant height: 4.47"))
        XCTAssertTrue(result.text.contains("Volume: 205.25"))
        XCTAssertTrue(result.text.contains("161.00°"))
    }

    func testDartSplitsThreeToOne() throws {
        let result = try PatternGeometryTool.dart.run(["largeCircumference": 30, "smallCircumference": 26])
        XCTAssertTrue(result.text.contains("Total intake: 4.00"))
        XCTAssertTrue(result.text.contains("Front: 3.00, back: 1.00"))
    }

    func testGussetAndChibi() throws {
        let gusset = try PatternGeometryTool.headGusset.run(["sidePerimeter": 30, "sideHeight": 12])
        XCTAssertTrue(gusset.text.contains("width: 8.00"))
        let chibi = try PatternGeometryTool.chibiHead.run(["totalHeight": 20])
        XCTAssertTrue(chibi.text.contains("Head height: 8.00"))
    }

    func testInvalidInputsAreRejected() {
        XCTAssertThrowsError(try PatternGeometryTool.sphereGores.run(["radius": 5, "gores": 6.5]))
        XCTAssertThrowsError(try PatternGeometryTool.sphereGores.run(["radius": -1, "gores": 6]))
        XCTAssertThrowsError(try PatternGeometryTool.frustum.run(["bigRadius": 3, "smallRadius": 3, "height": 4]))
        XCTAssertThrowsError(try PatternGeometryTool.dart.run(["largeCircumference": 20]))
        XCTAssertThrowsError(try PatternGeometryTool.cylinder.run(["diameter": .nan, "height": 2]))
    }
}

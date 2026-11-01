import XCTest
@testable import TopologyKit

final class AreaPreservingUVRefinerTests: XCTestCase {
    func testRefinementReducesAreaDistortionWithoutFlippingTriangles() throws {
        let positions = [
            Vec3(0, 0, 0),
            Vec3(2, 0, 0),
            Vec3(2, 2, 0),
            Vec3(0, 2, 0),
            Vec3(1, 1, 0),
        ]
        let triangles: [Int32] = [
            0, 1, 4,
            1, 2, 4,
            2, 3, 4,
            3, 0, 4,
        ]
        let patch = SurfacePatch.whole(positions: positions, triangles: triangles)
        let initialUV = [
            Vec2(0, 0),
            Vec2(2, 0),
            Vec2(2, 2),
            Vec2(0, 2),
            Vec2(1.3, 1.3),
        ]
        let refined = try AreaPreservingUVRefiner.refine(
            patch: patch,
            boundaryLoop: [0, 1, 2, 3],
            initialUV: initialUV
        )
        let initialReport = DistortionVerifier.verify(
            positions: positions,
            triangles: triangles,
            uv: initialUV,
            areaFactor: 1,
            tolerance: 1,
            requireLocalAccuracy: true
        )
        let refinedReport = DistortionVerifier.verify(
            positions: positions,
            triangles: triangles,
            uv: refined,
            areaFactor: 1,
            tolerance: 1,
            requireLocalAccuracy: true
        )

        XCTAssertLessThan(refinedReport.meanLocalDistortion, initialReport.meanLocalDistortion)
        XCTAssertEqual(refinedReport.flippedTriangles, 0)
        XCTAssertLessThanOrEqual(refinedReport.areaDelta, initialReport.areaDelta)
    }
}

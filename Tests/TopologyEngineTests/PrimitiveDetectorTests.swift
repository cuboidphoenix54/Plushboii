import XCTest
@testable import TopologyKit

final class PrimitiveDetectorTests: XCTestCase {
    typealias Mesh = (positions: [Vec3], triangles: [Int32])

    /// Solid of revolution about +Z from a profile of (radius, z); the first and last radii may be 0 (poles).
    private func revolve(_ profile: [(Double, Double)], segments: Int = 48) -> Mesh {
        var p: [Vec3] = [], t: [Int32] = []
        var rings: [Int] = []
        let body = profile.filter { $0.0 > 0 }
        for (r, z) in body {
            rings.append(p.count)
            for i in 0..<segments { let a = 2 * Double.pi * Double(i) / Double(segments); p.append(Vec3(r * cos(a), r * sin(a), z)) }
        }
        for k in 0..<(rings.count - 1) {
            for i in 0..<segments {
                let a = Int32(rings[k] + i), b = Int32(rings[k] + (i + 1) % segments), c = Int32(rings[k + 1] + i), d = Int32(rings[k + 1] + (i + 1) % segments)
                t += [a, b, d, a, d, c]
            }
        }
        func pole(z: Double, ring: Int, flip: Bool) {
            p.append(Vec3(0, 0, z)); let c = Int32(p.count - 1)
            for i in 0..<segments {
                let a = Int32(ring + i), b = Int32(ring + (i + 1) % segments)
                t += flip ? [a, c, b] : [a, b, c]
            }
        }
        pole(z: profile.first!.1, ring: rings.first!, flip: false)
        pole(z: profile.last!.1, ring: rings.last!, flip: true)
        return (p, t)
    }

    private func sphere() -> Mesh {
        var profile: [(Double, Double)] = []
        for k in 0...24 {
            let angle: Double = Double.pi * Double(k) / 24.0
            let radius: Double = (k == 0 || k == 24) ? 0.0 : sin(angle)
            profile.append((radius, -cos(angle)))
        }
        return revolve(profile)
    }
    private func cylinder() -> Mesh {
        var profile: [(Double, Double)] = [(0.0, -1.0)]
        for k in 0...10 { profile.append((1.0, -1.0 + 0.2 * Double(k))) }
        profile.append((0.0, 1.0))
        return revolve(profile)
    }
    private func cone() -> Mesh {
        var profile: [(Double, Double)] = [(0.0, -1.0)]
        for k in 0..<16 {
            let f: Double = Double(k) / 16.0
            profile.append((1.0 - f, -1.0 + 2.0 * f))
        }
        profile.append((0.0, 1.0))
        return revolve(profile)
    }

    private func box(_ s: Vec3, seg: Int = 6) -> Mesh {
        var p: [Vec3] = [], t: [Int32] = []
        let faces: [(Vec3, Vec3, Vec3)] = [(Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)), (Vec3(-1, 0, 0), Vec3(0, 0, 1), Vec3(0, 1, 0)),
                                           (Vec3(0, 1, 0), Vec3(0, 0, 1), Vec3(1, 0, 0)), (Vec3(0, -1, 0), Vec3(1, 0, 0), Vec3(0, 0, 1)),
                                           (Vec3(0, 0, 1), Vec3(1, 0, 0), Vec3(0, 1, 0)), (Vec3(0, 0, -1), Vec3(0, 1, 0), Vec3(1, 0, 0))]
        var index: [String: Int32] = [:]
        func vertex(_ v: Vec3) -> Int32 {
            let key = String(format: "%.4f,%.4f,%.4f", v.x, v.y, v.z)
            if let i = index[key] { return i }
            p.append(v * s); index[key] = Int32(p.count - 1); return Int32(p.count - 1)
        }
        for (n, u, v) in faces {
            for j in 0..<seg { for i in 0..<seg {
                func q(_ a: Int, _ b: Int) -> Int32 { vertex(n + u * (2 * Double(a) / Double(seg) - 1) + v * (2 * Double(b) / Double(seg) - 1)) }
                let (p00, p10, p01, p11) = (q(i, j), q(i + 1, j), q(i, j + 1), q(i + 1, j + 1))
                t += [p00, p10, p11, p00, p11, p01]
            } }
        }
        return (p, t)
    }

    func testSphereIsRecognisedAndGoredPoleToPole() throws {
        let m = sphere()
        let fit = try XCTUnwrap(PrimitiveDetector.detect(positions: m.positions, triangles: m.triangles))
        XCTAssertEqual(fit.kind, .sphere)
        let parts = PrimitiveSplitter.meridianGoreComponents(positions: m.positions, triangles: m.triangles, axis: try XCTUnwrap(fit.axis), center: fit.center, count: 6)
        XCTAssertEqual(parts.count, 6)
        let areas = parts.map(\.surfaceArea)
        XCTAssertLessThan((areas.max() ?? 0) / max(areas.min() ?? 1, 1e-9), 1.15)
    }

    func testCylinderIsATubeWithTwoCaps() throws {
        let m = cylinder()
        let fit = try XCTUnwrap(PrimitiveDetector.detect(positions: m.positions, triangles: m.triangles))
        XCTAssertEqual(fit.kind, .cylinder)
        let parts = PrimitiveSplitter.tubeComponents(positions: m.positions, triangles: m.triangles, axis: try XCTUnwrap(fit.axis), center: fit.center)
        XCTAssertEqual(parts.map(\.anatomicalLabel), ["Side band", "Bottom cap", "Top cap"])
    }

    func testConeIsTaperedWithBaseAtTheFlatEnd() throws {
        let m = cone()
        let fit = try XCTUnwrap(PrimitiveDetector.detect(positions: m.positions, triangles: m.triangles))
        XCTAssertEqual(fit.kind, .cone)
        let axis = try XCTUnwrap(fit.axis)
        let rotated = PrimitiveDetector.align(m.positions, axis: axis, center: fit.center)
        let top = rotated.map(\.y).max() ?? 0, bottom = rotated.map(\.y).min() ?? 0
        let baseRadius = rotated.filter { $0.y < bottom + 0.05 * (top - bottom) }.map { ($0.x * $0.x + $0.z * $0.z).squareRoot() }.max() ?? 0
        XCTAssertEqual(fit.baseAtHigh, baseRadius < 0.5)
    }

    func testBoxBecomesSixFaces() throws {
        let m = box(Vec3(1, 1, 1.8))
        let fit = try XCTUnwrap(PrimitiveDetector.detect(positions: m.positions, triangles: m.triangles))
        XCTAssertEqual(fit.kind, .box)
        XCTAssertEqual(PrimitiveSplitter.facetComponents(positions: m.positions, triangles: m.triangles).count, 6)
    }

    func testTiltedCylinderStillFindsItsAxis() throws {
        let m = cylinder()
        let tilted = PrimitiveDetector.align(m.positions, axis: Vec3(0, 0, 1), center: .zero).map { Vec3($0.x * 0.8 + $0.y * 0.6, $0.y * 0.8 - $0.x * 0.6, $0.z) }
        let fit = try XCTUnwrap(PrimitiveDetector.detect(positions: tilted, triangles: m.triangles))
        XCTAssertEqual(fit.kind, .cylinder)
    }

    func testCreatureLikeBlobIsNotAPrimitive() {
        var p = sphere().positions
        let t = sphere().triangles
        for i in p.indices where p[i].z > 0.3 && p[i].x > 0 { p[i].x += 0.8 * p[i].z }
        XCTAssertNil(PrimitiveDetector.detect(positions: p, triangles: t))
    }

    func testTubeBandSeamAvoidsConspicuousRegion() throws {
        let m = cylinder()
        let fit = try XCTUnwrap(PrimitiveDetector.detect(positions: m.positions, triangles: m.triangles))
        let parts = PrimitiveSplitter.tubeComponents(positions: m.positions, triangles: m.triangles, axis: try XCTUnwrap(fit.axis), center: fit.center)
        let band = try XCTUnwrap(parts.first)
        let plain = try XCTUnwrap(PrimitiveSeams.tubeBandSuggestion(positions: band.positions, triangles: band.triangles, fabric: .none, visibility: .none))
        XCTAssertEqual(plain.panelCount, 1)
        XCTAssertEqual(plain.seamPaths.count, 1)
        // Mark the half of the band the plain seam runs through as a face, then require the new seam to leave it.
        let seamPoint = band.positions[plain.seamPaths[0][0]]
        let lo = band.positions.reduce(band.positions[0]) { Vec3(min($0.x, $1.x), min($0.y, $1.y), min($0.z, $1.z)) }
        let hi = band.positions.reduce(band.positions[0]) { Vec3(max($0.x, $1.x), max($0.y, $1.y), max($0.z, $1.z)) }
        func norm(_ v: Double, _ a: Double, _ b: Double) -> Double { b > a ? (v - a) / (b - a) : 0.5 }
        let nx = norm(seamPoint.x, lo.x, hi.x), nz = norm(seamPoint.z, lo.z, hi.z)
        let region = VisibleRegion(name: "face", min: [max(nx - 0.2, 0), 0, max(nz - 0.2, 0)], max: [min(nx + 0.2, 1), 1, min(nz + 0.2, 1)], weight: 1)
        let steered = try XCTUnwrap(PrimitiveSeams.tubeBandSuggestion(positions: band.positions, triangles: band.triangles, fabric: .none,
                                                                      visibility: SeamVisibility(regions: [region]).bound(to: band.positions)))
        let visibility = SeamVisibility(regions: [region]).bound(to: band.positions)
        XCTAssertLessThanOrEqual(visibility.penalty(of: steered.seamPaths, positions: band.positions), visibility.penalty(of: plain.seamPaths, positions: band.positions))
        XCTAssertEqual(visibility.penalty(of: steered.seamPaths, positions: band.positions), 0, accuracy: 1e-9)
    }
}

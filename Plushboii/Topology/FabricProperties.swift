import Foundation

/// Fabric behaviour on four independent axes (warp stretch, weft stretch, shear, bending), the same breakdown
/// that garment-simulation tools expose, instead of a single stretch percentage.
///
/// The presets are adjustable starting points for typical plush fabrics, not laboratory measurements: tune
/// them against a swatch (pull along each grain, then on the bias) before relying on the strain verdicts.
struct FabricProperties: Sendable, Equatable {
    var name: String
    /// Stretch the pattern relies on along the warp / weft (island U / V), in percent.
    var warpStretchPercent: Double
    var weftStretchPercent: Double
    /// Largest in-plane shear the fabric tolerates before it distorts visibly, in degrees.
    var shearLimitDegrees: Double
    /// 0 = limp (drapes into folds), 1 = stiff (resists bunching).
    var bendingStiffness: Double
    /// Rigid fabrics are relieved with darts instead of negative ease.
    var maximumDarts: Int?

    static let wovenCotton = FabricProperties(name: "Woven cotton", warpStretchPercent: 0, weftStretchPercent: 0, shearLimitDegrees: 6, bendingStiffness: 0.7, maximumDarts: 6)
    static let felt = FabricProperties(name: "Felt", warpStretchPercent: 0, weftStretchPercent: 0, shearLimitDegrees: 10, bendingStiffness: 0.8, maximumDarts: 6)
    static let fleece = FabricProperties(name: "Fleece", warpStretchPercent: 20, weftStretchPercent: 30, shearLimitDegrees: 15, bendingStiffness: 0.3, maximumDarts: nil)
    static let minky = FabricProperties(name: "Minky", warpStretchPercent: 30, weftStretchPercent: 50, shearLimitDegrees: 20, bendingStiffness: 0.2, maximumDarts: nil)

    var profile: FabricProfile {
        if let maximumDarts { return .rigid(maxDarts: maximumDarts) }
        return .twoWayStretch(warpPercent: warpStretchPercent, weftPercent: weftStretchPercent)
    }

    /// Properties implied by a flattening profile, for when only the profile is known.
    static func inferred(from profile: FabricProfile) -> FabricProperties {
        switch profile {
        case .none, .rigid(_, _):
            var base = wovenCotton
            base.name = "Rigid fabric"
            if case .rigid(let darts, _) = profile { base.maximumDarts = darts }
            return base
        case .twoWayStretch(let warp, let weft, _):
            var base = fleece
            base.name = "Stretch fabric"
            base.warpStretchPercent = warp
            base.weftStretchPercent = weft
            return base
        }
    }

    /// Mean of the two stretch limits as a fraction; the isotropic approximation used by the stuffing simulation.
    var meanStretchFraction: Double { (warpStretchPercent + weftStretchPercent) / 200 }

    /// Compression a stiffer fabric will not absorb as bunching, as a fraction of edge length.
    var bunchAllowance: Double { 0.02 + 0.10 * (1 - min(max(bendingStiffness, 0), 1)) }
}

/// Weft/warp-aware strain of a flattened panel, in the manner of the stress-limited distortion measure of
/// Pietroni et al. (ACM TOG 2022). Where the 5% area rule only sees net area change, this reports how much the
/// fabric must stretch along each grain direction and shear on the bias to cover the 3D surface.
enum AnisotropicStrain {
    struct Report: Sendable, Equatable {
        /// Largest and smallest strain along the warp, as fractions (0.1 = fabric must stretch 10%).
        let worstWarpStretch: Double
        let worstWarpCompression: Double
        let worstWeftStretch: Double
        let worstWeftCompression: Double
        let worstShearDegrees: Double
        /// Share of 3D area whose strain or shear exceeds what the fabric allows.
        let overstretchedShare: Double
        let bunchedShare: Double
        let overshearedShare: Double
        let flippedTriangles: Int

        var passed: Bool { flippedTriangles == 0 && overstretchedShare < 0.05 && overshearedShare < 0.05 }
    }

    /// Strain allowance for fabrics that are not meant to stretch.
    static let rigidAllowance = 0.03

    /// `positions` are the mesh the island was cut from. The island UV is taken as final (after fabric easing),
    /// in the same units as `positions`; for non-stretch profiles the grain axes are rotated by the grain angle.
    static func analyze(island: UVIsland, positions: [Vec3], properties: FabricProperties, grainAngle: Double = 0) -> Report {
        let warpAllowance = properties.maximumDarts == nil ? properties.warpStretchPercent / 100 : rigidAllowance
        let weftAllowance = properties.maximumDarts == nil ? properties.weftStretchPercent / 100 : rigidAllowance
        let bunch = properties.bunchAllowance
        let c = cos(grainAngle), s = sin(grainAngle)
        let warpAxis = properties.maximumDarts == nil ? Vec2(1, 0) : Vec2(c, s)
        let weftAxis = properties.maximumDarts == nil ? Vec2(0, 1) : Vec2(-s, c)

        var totalArea = 0.0, over = 0.0, bunched = 0.0, sheared = 0.0
        var warpMax = -Double.infinity, warpMin = Double.infinity, weftMax = -Double.infinity, weftMin = Double.infinity
        var shearMax = 0.0
        var flipped = 0

        for t in 0..<(island.triangles.count / 3) {
            let a = Int(island.triangles[t * 3]), b = Int(island.triangles[t * 3 + 1]), d = Int(island.triangles[t * 3 + 2])
            let p0 = island.sourcePosition(a, positions), p1 = island.sourcePosition(b, positions), p2 = island.sourcePosition(d, positions)
            let e1 = p1 - p0, e2 = p2 - p0
            let l1 = vlength(e1)
            guard l1 > 1e-14 else { continue }
            let ex = e1 / l1
            let px = vdot(e2, ex), py = vlength(e2 - ex * px)
            guard py > 1e-14 else { continue }
            let area = 0.5 * l1 * py
            let u1 = island.uv[b] - island.uv[a], u2 = island.uv[d] - island.uv[a]
            // J = [u1 u2] D⁻¹ maps rest-plane vectors to panel vectors; its inverse gives the 3D length behind a panel direction.
            let inv = (a: 1 / l1, b: -px / (l1 * py), d: 1 / py)
            let j00 = u1.x * inv.a, j01 = u1.x * inv.b + u2.x * inv.d
            let j10 = u1.y * inv.a, j11 = u1.y * inv.b + u2.y * inv.d
            let det = j00 * j11 - j01 * j10
            totalArea += area
            if det <= 0 { flipped += 1; continue }
            func back(_ g: Vec2) -> Vec2 { Vec2(j11 * g.x - j01 * g.y, -j10 * g.x + j00 * g.y) / det }
            let warp3D = back(warpAxis), weft3D = back(weftAxis)
            let warpStrain = vlength(warp3D) - 1, weftStrain = vlength(weft3D) - 1
            let cosine = vdot(warp3D, weft3D) / max(vlength(warp3D) * vlength(weft3D), 1e-300)
            let shear = abs(90 - acos(min(max(cosine, -1), 1)) * 180 / .pi)
            warpMax = max(warpMax, warpStrain); warpMin = min(warpMin, warpStrain)
            weftMax = max(weftMax, weftStrain); weftMin = min(weftMin, weftStrain)
            shearMax = max(shearMax, shear)
            if warpStrain > warpAllowance + 1e-9 || weftStrain > weftAllowance + 1e-9 { over += area }
            if warpStrain < -bunch || weftStrain < -bunch { bunched += area }
            if shear > properties.shearLimitDegrees { sheared += area }
        }
        let share = { (value: Double) in totalArea > 0 ? value / totalArea : 0 }
        return Report(
            worstWarpStretch: warpMax.isFinite ? warpMax : 0, worstWarpCompression: warpMin.isFinite ? warpMin : 0,
            worstWeftStretch: weftMax.isFinite ? weftMax : 0, worstWeftCompression: weftMin.isFinite ? weftMin : 0,
            worstShearDegrees: shearMax,
            overstretchedShare: share(over), bunchedShare: share(bunched), overshearedShare: share(sheared),
            flippedTriangles: flipped
        )
    }
}

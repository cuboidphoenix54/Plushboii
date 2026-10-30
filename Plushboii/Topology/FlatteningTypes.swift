import Foundation

/// Material model used to adjust or relieve a flattened island.
enum FabricProfile: Sendable, Equatable {
    /// Geometry only: no elasticity adjustment.
    case none
    /// Two-way stretch (for example minky). Percentages are the stretch the garment relies on along
    /// the warp (island U) and weft (island V) after `grainAngle` is applied. The island is shrunk by
    /// the negative-ease matrix diag(1 / (1 + warp), 1 / (1 + weft)).
    case twoWayStretch(warpPercent: Double, weftPercent: Double, grainAngle: Double = 0)
    /// Non-stretch fabric (for example canvas). Excess curvature is relieved with up to `maxDarts` darts.
    case rigid(maxDarts: Int = 6, grainAngle: Double = 0)

    var isRigid: Bool {
        if case .rigid = self { return true }
        return false
    }

    var maxDarts: Int {
        if case .rigid(let darts, _) = self { return darts }
        return 0
    }

    func validated() throws {
        switch self {
        case .none:
            return
        case .twoWayStretch(let warp, let weft, let angle):
            for percent in [warp, weft] {
                guard percent.isFinite, percent >= 0, percent <= 200 else {
                    throw FlatteningError.invalidFabric("stretch must be between 0% and 200%")
                }
            }
            guard angle.isFinite else { throw FlatteningError.invalidFabric("grain angle must be finite") }
        case .rigid(let darts, let angle):
            guard darts >= 0, darts <= 64 else {
                throw FlatteningError.invalidFabric("dart count must be between 0 and 64")
            }
            guard angle.isFinite else { throw FlatteningError.invalidFabric("grain angle must be finite") }
        }
    }

    var grainAngle: Double {
        switch self {
        case .none: 0
        case .twoWayStretch(_, _, let angle): angle
        case .rigid(_, let angle): angle
        }
    }

    /// Negative-ease scaling applied to the island, expressed as a 2x2 matrix.
    var scalingMatrix: Matrix2 {
        switch self {
        case .twoWayStretch(let warp, let weft, _):
            Matrix2(a: 1 / (1 + warp / 100), b: 0, c: 0, d: 1 / (1 + weft / 100))
        case .none, .rigid:
            .identity
        }
    }
}

struct Matrix2: Sendable, Equatable {
    var a: Double, b: Double
    var c: Double, d: Double

    static let identity = Matrix2(a: 1, b: 0, c: 0, d: 1)

    var determinant: Double { a * d - b * c }

    func apply(_ p: Vec2) -> Vec2 {
        Vec2(a * p.x + b * p.y, c * p.x + d * p.y)
    }

    static func rotation(_ angle: Double) -> Matrix2 {
        Matrix2(a: cos(angle), b: -sin(angle), c: sin(angle), d: cos(angle))
    }
}

struct DistortionReport: Sendable, Equatable {
    let area3D: Double
    let area2D: Double
    /// Area the island should have: the 3D area times the fabric's area scaling.
    let expectedArea2D: Double
    /// |area2D - expectedArea2D| / expectedArea2D
    let areaDelta: Double
    let tolerance: Double
    /// Area-weighted mean of |local area ratio - 1| across triangles.
    let meanLocalDistortion: Double
    let maxLocalDistortion: Double
    let flippedTriangles: Int
    let passed: Bool
}

struct VerificationRecord: Sendable, Equatable {
    let dartCount: Int
    let attempt: Int
    let areaDelta: Double
    let meanLocalDistortion: Double
    let flippedTriangles: Int
    let accepted: Bool
}

struct Dart: Sendable, Equatable {
    /// Original-mesh vertex where the dart ends (the point of highest curvature).
    let apexVertex: Int
    /// Original-mesh vertices from the apex to the island edge, along which the surface was cut.
    let pathVertices: [Int]
    /// Wedge angle removed at the apex, in radians (2π minus the flattened angle sum).
    let openingAngle: Double
    /// Distance between the two copies of the edge vertex, in island units.
    let mouthWidth: Double
    let legLength: Double
}

struct UVIsland: Sendable {
    let segmentIndex: Int
    /// Flat triangle list with island-local vertex indices.
    let triangles: [Int32]
    let uv: [Vec2]
    /// Original-mesh vertex index for each island vertex (cut vertices appear more than once).
    let sourceVertex: [Int]
    let darts: [Dart]
    /// Verification of the geometric flattening, before fabric adjustment.
    let geometryReport: DistortionReport
    /// Verification of the final coordinates, after fabric adjustment.
    let report: DistortionReport
    let log: [VerificationRecord]
}

struct FlatteningResult: Sendable {
    let islands: [UVIsland]
    let fabric: FabricProfile
}

enum FlatteningError: LocalizedError, Equatable {
    case invalidMesh(String)
    case invalidFabric(String)
    case invalidTolerance
    case seamEdgeNotOnMesh(Int, Int)
    case nonManifoldEdge
    case notDisc(segment: Int, euler: Int, boundaryLoops: Int)
    case degenerateTriangle
    case solverDidNotConverge(relativeResidual: Double)
    case distortionExceeded(segment: Int, areaDelta: Double, meanLocal: Double, flipped: Int, darts: Int)
    case verificationFailed(segment: Int)

    var errorDescription: String? {
        switch self {
        case .invalidMesh(let reason):
            "The mesh cannot be flattened: \(reason)."
        case .invalidFabric(let reason):
            "Invalid fabric profile: \(reason)."
        case .invalidTolerance:
            "The distortion tolerance must be a finite value greater than zero."
        case .seamEdgeNotOnMesh(let a, let b):
            "Seam edge \(a)–\(b) is not an edge of the mesh."
        case .nonManifoldEdge:
            "The mesh has an edge shared by more than two triangles."
        case .notDisc(let segment, let euler, let loops):
            "Segment \(segment) is not a disc (Euler characteristic \(euler), \(loops) boundary loops). Add seams to open it up."
        case .degenerateTriangle:
            "The mesh contains a zero-area triangle."
        case .solverDidNotConverge(let residual):
            "The LSCM solver did not converge (relative residual \(residual))."
        case .distortionExceeded(let segment, let delta, let meanLocal, let flipped, let darts):
            "Segment \(segment) was rejected after re-mapping: area delta \(Self.percent(delta)), mean local distortion \(Self.percent(meanLocal)), \(flipped) flipped triangles, \(darts) darts. Add seams to reduce curvature."
        case .verificationFailed(let segment):
            "Segment \(segment) failed the final verification after the fabric adjustment."
        }
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.2f%%", value * 100)
    }
}

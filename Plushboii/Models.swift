import Foundation
import SwiftData

@Model
final class Pattern {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var modifiedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \PatternPiece.pattern)
    var pieces: [PatternPiece]

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        pieces: [PatternPiece] = []
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.pieces = pieces
    }
}

@Model
final class PatternPiece {
    @Attribute(.unique) var id: UUID
    var name: String
    var sortOrder: Int
    var sourceMeshFormat: String?
    var faceIndexData: Data
    var seamPathData: Data = Data()
    /// Packed little-endian Float64 x,y,z triples. Preferred over `controlPoints`, which stays only for
    /// pieces stored before this field existed (one SwiftData object per vertex is too slow for dense scans).
    var vertexData: Data = Data()
    var pattern: Pattern?

    @Relationship(deleteRule: .cascade, inverse: \ControlPoint.piece)
    var controlPoints: [ControlPoint]

    init(
        id: UUID = UUID(),
        name: String,
        sortOrder: Int,
        sourceMeshFormat: String? = nil,
        faceIndexData: Data = Data(),
        seamPathData: Data = Data(),
        vertexData: Data = Data(),
        pattern: Pattern? = nil,
        controlPoints: [ControlPoint] = []
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.sourceMeshFormat = sourceMeshFormat
        self.faceIndexData = faceIndexData
        self.seamPathData = seamPathData
        self.vertexData = vertexData
        self.pattern = pattern
        self.controlPoints = controlPoints
    }
}

@Model
final class ControlPoint {
    @Attribute(.unique) var id: UUID
    var index: Int
    var x: Double
    var y: Double
    var z: Double
    var u: Double?
    var v: Double?
    var piece: PatternPiece?

    init(
        id: UUID = UUID(),
        index: Int,
        x: Double,
        y: Double,
        z: Double,
        u: Double? = nil,
        v: Double? = nil,
        piece: PatternPiece? = nil
    ) {
        self.id = id
        self.index = index
        self.x = x
        self.y = y
        self.z = z
        self.u = u
        self.v = v
        self.piece = piece
    }
}

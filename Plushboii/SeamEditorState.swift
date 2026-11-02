import Foundation
import Observation

struct SeamPath: Equatable, Sendable, Identifiable {
    let id = UUID()
    /// Contiguous mesh-vertex indices; consecutive entries share a mesh edge.
    var vertices: [Int]
    /// For each user pick, the vertex count of the path once that pick was added (used for undo).
    var anchorEnds: [Int]
    var isClosed = false

    var anchors: [Int] {
        anchorEnds.compactMap { $0 >= 1 && $0 <= vertices.count ? vertices[$0 - 1] : nil }
    }
}

@MainActor
@Observable
final class SeamEditorState {
    private(set) var mesh: MeshTopology?
    private(set) var seams: [SeamPath] = []
    private(set) var loadedPieceID: UUID?
    private(set) var isLoading = false
    private(set) var isBusy = false
    private(set) var message: String?

    @ObservationIgnored private var startsNewSeam = false
    @ObservationIgnored private var lastSuggestionSeamCount = 0

    func load(piece: PatternPiece?) async {
        mesh = nil
        seams = []
        loadedPieceID = nil
        message = nil
        startsNewSeam = false
        lastSuggestionSeamCount = 0
        guard let piece else { return }

        let pieceID = piece.id
        let vertexData = piece.vertexData
        let points = vertexData.isEmpty
            ? piece.controlPoints.map { RawControlPoint(index: $0.index, x: $0.x, y: $0.y, z: $0.z) }
            : []
        let faceData = piece.faceIndexData
        let seamData = piece.seamPathData
        guard !(points.isEmpty && vertexData.isEmpty), !faceData.isEmpty else {
            loadedPieceID = pieceID
            return
        }

        isLoading = true
        let loaded = await Task.detached(priority: .userInitiated) {
            MeshTopology.load(points: points, vertexData: vertexData, faceData: faceData, seamData: seamData)
        }.value
        guard !Task.isCancelled else { return }
        isLoading = false

        if let loaded {
            mesh = loaded.topology
            seams = loaded.seams
        } else {
            message = "The stored mesh is invalid, so the seam tool is unavailable."
        }
        loadedPieceID = pieceID
    }

    func startNewSeam() {
        startsNewSeam = true
        lastSuggestionSeamCount = 0
        message = "Next click starts a new seam."
    }

    func applySuggestion(_ paths: [[Int]]) {
        guard let topology = mesh, !paths.isEmpty,
              paths.allSatisfy({ vertices in
                  vertices.count >= 2
                      && vertices.allSatisfy(topology.positions.indices.contains)
                      && zip(vertices, vertices.dropFirst()).allSatisfy(topology.isAdjacent)
              })
        else {
            message = "That suggested panel layout contains a cut that is not connected on this mesh."
            return
        }
        seams.append(contentsOf: paths.map { SeamPath(vertices: $0, anchorEnds: [1, $0.count]) })
        lastSuggestionSeamCount = paths.count
        startsNewSeam = false
        message = "Suggested panel layout applied. Use the seam tool to edit it, or Undo to remove the layout."
    }

    func pick(vertex: Int, startingNewSeam shiftHeld: Bool) async {
        guard let topology = mesh, !isBusy, topology.positions.indices.contains(vertex) else { return }
        lastSuggestionSeamCount = 0
        isBusy = true
        defer { isBusy = false }
        message = nil

        if shiftHeld { startsNewSeam = true }
        if seams.isEmpty || startsNewSeam || seams[seams.count - 1].isClosed {
            startsNewSeam = false
            seams.append(SeamPath(vertices: [vertex], anchorEnds: [1]))
            return
        }

        var seam = seams[seams.count - 1]
        guard let tail = seam.vertices.last, tail != vertex else { return }
        let path = await Task.detached(priority: .userInitiated) {
            topology.shortestPath(from: tail, to: vertex)
        }.value

        guard mesh?.id == topology.id, let path, path.count >= 2 else {
            message = "No connected surface path to that point; the pick was ignored."
            return
        }
        seam.vertices.append(contentsOf: path.dropFirst())
        seam.anchorEnds.append(seam.vertices.count)
        seams[seams.count - 1] = seam
    }

    func closeActiveSeam() async {
        guard let topology = mesh, !isBusy, var seam = seams.last, !seam.isClosed, seam.anchorEnds.count >= 3,
              let tail = seam.vertices.last, let head = seam.vertices.first
        else {
            message = "A loop needs at least three picks."
            return
        }
        lastSuggestionSeamCount = 0
        isBusy = true
        defer { isBusy = false }
        let path = await Task.detached(priority: .userInitiated) {
            topology.shortestPath(from: tail, to: head)
        }.value
        guard mesh?.id == topology.id, let path, path.count >= 2 else {
            message = "Could not close the loop along the surface."
            return
        }
        seam.vertices.append(contentsOf: path.dropFirst())
        seam.anchorEnds.append(seam.vertices.count)
        seam.isClosed = true
        seams[seams.count - 1] = seam
        message = nil
    }

    func undo() {
        if lastSuggestionSeamCount > 0 {
            seams.removeLast(min(lastSuggestionSeamCount, seams.count))
            lastSuggestionSeamCount = 0
            message = "Suggested panel layout removed."
            return
        }
        guard var seam = seams.last else { return }
        if seam.anchorEnds.count <= 1 {
            seams.removeLast()
            return
        }
        seam.anchorEnds.removeLast()
        seam.vertices.removeLast(seam.vertices.count - (seam.anchorEnds.last ?? 0))
        seam.isClosed = false
        seams[seams.count - 1] = seam
    }

    func clearAll() {
        seams = []
        startsNewSeam = false
        lastSuggestionSeamCount = 0
        message = nil
    }
}

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

    func load(piece: PatternPiece?) async {
        mesh = nil
        seams = []
        loadedPieceID = nil
        message = nil
        startsNewSeam = false
        guard let piece else { return }

        let pieceID = piece.id
        let points = piece.controlPoints.map { RawControlPoint(index: $0.index, x: $0.x, y: $0.y, z: $0.z) }
        let faceData = piece.faceIndexData
        let seamData = piece.seamPathData
        guard !points.isEmpty, !faceData.isEmpty else {
            loadedPieceID = pieceID
            return
        }

        isLoading = true
        let loaded = await Task.detached(priority: .userInitiated) {
            MeshTopology.load(points: points, faceData: faceData, seamData: seamData)
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
        message = "Next click starts a new seam."
    }

    func pick(vertex: Int, startingNewSeam shiftHeld: Bool) async {
        guard let topology = mesh, !isBusy, topology.positions.indices.contains(vertex) else { return }
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
        message = nil
    }
}

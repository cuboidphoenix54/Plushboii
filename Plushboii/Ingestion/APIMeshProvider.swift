import Foundation
import UniformTypeIdentifiers

@MainActor
final class APIMeshProvider: MeshIngestionService {
    private let apiKey: String
    private let imageURL: URL

    /// Where the downloaded OBJ and USDZ files were saved, once `ingest()` has succeeded.
    private(set) var savedFilesDirectory: URL?

    init(apiKey: String, imageURL: URL) {
        self.apiKey = apiKey
        self.imageURL = imageURL
    }

    let sourceFormat = "obj"
    let suggestedName = "Generated Mesh"

    /// Upload, poll, download, parse and validate. Any timeout, HTTP failure, failed task or malformed payload
    /// throws a typed `MeshyError`/`MeshIngestionError`; geometry is only returned after `MeshSchemaEnforcer` passes.
    func ingest() async throws -> IngestedMesh {
        guard !apiKey.isEmpty else { throw MeshyError.missingAPIKey }
        let url = imageURL
        let mimeType = Self.mimeType(for: url)
        let imageData = try await offMainActor { try Self.readImage(at: url) }

        let result = try await MeshyClient(apiKey: apiKey).generate(from: imageData, mimeType: mimeType)
        let render = try await MeshRenderData.prepare(result.mesh)
        try Task.checkCancellation()
        savedFilesDirectory = result.objFileURL.deletingLastPathComponent()
        return (render.makeNode(), result.mesh)
    }

    private nonisolated static func readImage(at url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw MeshyError.invalidImage
        }
    }

    private nonisolated static func mimeType(for url: URL) -> String {
        guard
            let type = UTType(filenameExtension: url.pathExtension),
            let mimeType = type.preferredMIMEType,
            ["image/jpeg", "image/png", "image/webp"].contains(mimeType)
        else {
            return "application/octet-stream"
        }
        return mimeType
    }
}

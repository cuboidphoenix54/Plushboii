import Foundation

struct MeshVertex: Sendable {
    let x: Double
    let y: Double
    let z: Double
}

struct MeshTriangle: Sendable {
    let a: Int
    let b: Int
    let c: Int
}

struct ImportedMesh: Sendable {
    let vertices: [MeshVertex]
    let triangles: [MeshTriangle]
}

struct MeshGenerationResult: Sendable {
    let mesh: ImportedMesh
    let objFileURL: URL
    let usdzFileURL: URL
}

enum MeshyError: LocalizedError {
    case missingAPIKey
    case invalidImage
    case imageTooLarge
    case invalidResponse
    case httpStatus(Int)
    case taskFailed(String)
    case pollingTimedOut
    case missingArtifact(String)
    case invalidArtifactURL
    case artifactTooLarge
    case malformedArtifact(String)
    case malformedOBJ(String)

    var errorDescription: String? {
        return switch self {
        case .missingAPIKey:
            "Enter a Meshy API key before starting a generation."
        case .invalidImage:
            "The selected file is not a supported image."
        case .imageTooLarge:
            "The image exceeds Meshy's 20 MB input limit."
        case .invalidResponse:
            "Meshy returned a malformed or incomplete response."
        case .httpStatus(let status):
            "Meshy returned HTTP \(status)."
        case .taskFailed(let message):
            "Meshy could not generate the model: \(message)"
        case .pollingTimedOut:
            "Meshy did not finish the generation task before the timeout."
        case .missingArtifact(let format):
            "Meshy's completed task did not include a \(format.uppercased()) file."
        case .invalidArtifactURL:
            "Meshy returned an invalid or insecure artifact URL."
        case .artifactTooLarge:
            "The downloaded model exceeds the 512 MB safety limit."
        case .malformedArtifact(let format):
            "Meshy's downloaded \(format.uppercased()) file is malformed."
        case .malformedOBJ(let reason):
            "The OBJ mesh is invalid: \(reason)"
        }
    }
}

actor MeshyClient {
    private let baseURL = URL(string: "https://api.meshy.ai/openapi/v1")!
    private let session: URLSession
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 900
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration)
    }

    func generate(from imageData: Data, mimeType: String) async throws -> MeshGenerationResult {
        guard ["image/jpeg", "image/png", "image/webp"].contains(mimeType) else {
            throw MeshyError.invalidImage
        }
        guard !imageData.isEmpty else { throw MeshyError.invalidImage }
        guard imageData.count <= 20 * 1024 * 1024 else { throw MeshyError.imageTooLarge }

        // Meshy's image-to-3D endpoint accepts a data URI in JSON, not multipart form data.
        let imageURI = "data:\(mimeType);base64,\(imageData.base64EncodedString())"
        let createURL = baseURL.appending(path: "image-to-3d")
        var createRequest = URLRequest(url: createURL)
        createRequest.httpMethod = "POST"
        createRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        createRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "image_url": imageURI,
            "target_formats": ["obj", "usdz"]
        ])

        let created: CreatedTask = try await send(createRequest, as: CreatedTask.self)
        guard UUID(uuidString: created.result) != nil else { throw MeshyError.invalidResponse }

        let completedTask = try await poll(taskID: created.result)
        guard let objURLString = completedTask.modelURLs?["obj"] else {
            throw MeshyError.missingArtifact("obj")
        }
        guard let usdzURLString = completedTask.modelURLs?["usdz"] else {
            throw MeshyError.missingArtifact("usdz")
        }
        guard
            let objURL = URL(string: objURLString),
            let usdzURL = URL(string: usdzURLString),
            objURL.scheme == "https",
            usdzURL.scheme == "https",
            objURL.host != nil,
            usdzURL.host != nil,
            objURL.user == nil,
            usdzURL.user == nil
        else {
            throw MeshyError.invalidArtifactURL
        }

        async let objFile = download(objURL, format: "obj")
        async let usdzFile = download(usdzURL, format: "usdz")
        let (objFileURL, usdzFileURL) = try await (objFile, usdzFile)
        let objData = try Data(contentsOf: objFileURL)
        let mesh = try Self.parseOBJ(objData)
        let usdzHandle = try FileHandle(forReadingFrom: usdzFileURL)
        defer { try? usdzHandle.close() }
        guard try usdzHandle.read(upToCount: 4) == Data([0x50, 0x4B, 0x03, 0x04]) else {
            throw MeshyError.malformedArtifact("usdz")
        }

        return MeshGenerationResult(mesh: mesh, objFileURL: objFileURL, usdzFileURL: usdzFileURL)
    }

    private func poll(taskID: String) async throws -> TaskStatus {
        let taskURL = baseURL.appending(path: "image-to-3d").appending(path: taskID)
        let deadline = ContinuousClock.now + .seconds(900)

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let status: TaskStatus = try await send(authorizedRequest(url: taskURL), as: TaskStatus.self)
            switch status.status.uppercased() {
            case "SUCCEEDED":
                return status
            case "FAILED", "CANCELED", "CANCELLED":
                throw MeshyError.taskFailed(status.taskError?.message ?? status.status)
            case "PENDING", "IN_PROGRESS":
                try await Task.sleep(for: .seconds(5))
            default:
                throw MeshyError.invalidResponse
            }
        }
        throw MeshyError.pollingTimedOut
    }

    private func download(_ url: URL, format: String) async throws -> URL {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (temporaryURL, response) = try await session.download(for: request)
        try validate(response)

        let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
        guard let fileSize = attributes[.size] as? NSNumber, fileSize.int64Value <= 512 * 1024 * 1024 else {
            throw MeshyError.artifactTooLarge
        }

        let supportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let outputDirectory = supportURL.appending(path: "Plushboii/Generated", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let destination = outputDirectory.appending(path: "\(UUID().uuidString).\(format)")
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private func send<Response: Decodable & Sendable>(
        _ request: URLRequest,
        as type: Response.Type
    ) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        try validate(response)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw MeshyError.invalidResponse
        }
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw MeshyError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw MeshyError.httpStatus(response.statusCode)
        }
    }

    private static func parseOBJ(_ data: Data) throws -> ImportedMesh {
        guard let text = String(data: data, encoding: .utf8) else {
            throw MeshyError.malformedOBJ("the file is not UTF-8 text")
        }

        var vertices: [MeshVertex] = []
        var triangles: [MeshTriangle] = []
        let maximumVertices = 2_000_000
        let maximumTriangles = 4_000_000

        for (lineNumber, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let content = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true).first ?? ""
            let fields = content.split(whereSeparator: \.isWhitespace)
            guard let kind = fields.first else { continue }
            switch kind {
            case "v":
                guard fields.count >= 4, vertices.count < maximumVertices,
                      let x = Double(fields[1]), let y = Double(fields[2]), let z = Double(fields[3]),
                      x.isFinite, y.isFinite, z.isFinite
                else {
                    throw MeshyError.malformedOBJ("invalid vertex at line \(lineNumber + 1)")
                }
                vertices.append(MeshVertex(x: x, y: y, z: z))
            case "f":
                guard fields.count >= 4 else {
                    throw MeshyError.malformedOBJ("face has fewer than three vertices at line \(lineNumber + 1)")
                }
                let indices = try fields.dropFirst().map { token -> Int in
                    guard let rawIndex = Int(token.split(separator: "/", omittingEmptySubsequences: false).first ?? ""),
                          rawIndex != 0
                    else {
                        throw MeshyError.malformedOBJ("invalid face index at line \(lineNumber + 1)")
                    }
                    let index = rawIndex > 0 ? rawIndex - 1 : vertices.count + rawIndex
                    guard index >= 0, index < vertices.count else {
                        throw MeshyError.malformedOBJ("face index is out of range at line \(lineNumber + 1)")
                    }
                    return index
                }
                for offset in 1..<(indices.count - 1) {
                    guard triangles.count < maximumTriangles else {
                        throw MeshyError.malformedOBJ("the mesh exceeds the triangle safety limit")
                    }
                    triangles.append(MeshTriangle(a: indices[0], b: indices[offset], c: indices[offset + 1]))
                }
            default:
                continue
            }
        }

        guard !vertices.isEmpty, !triangles.isEmpty else {
            throw MeshyError.malformedOBJ("no vertices or triangle faces were found")
        }
        for triangle in triangles {
            guard triangle.a != triangle.b, triangle.b != triangle.c, triangle.a != triangle.c else {
                throw MeshyError.malformedOBJ("a triangle repeats a vertex index")
            }
            let a = vertices[triangle.a]
            let b = vertices[triangle.b]
            let c = vertices[triangle.c]
            let ab = (b.x - a.x, b.y - a.y, b.z - a.z)
            let ac = (c.x - a.x, c.y - a.y, c.z - a.z)
            let cross = (
                ab.1 * ac.2 - ab.2 * ac.1,
                ab.2 * ac.0 - ab.0 * ac.2,
                ab.0 * ac.1 - ab.1 * ac.0
            )
            let doubledArea = sqrt(cross.0 * cross.0 + cross.1 * cross.1 + cross.2 * cross.2)
            guard doubledArea.isFinite, doubledArea > 0 else {
                throw MeshyError.malformedOBJ("a triangle is degenerate or has non-finite area")
            }
        }
        return ImportedMesh(vertices: vertices, triangles: triangles)
    }
}

private struct CreatedTask: Decodable, Sendable {
    let result: String
}

private struct TaskStatus: Decodable, Sendable {
    let status: String
    let modelURLs: [String: String]?
    let taskError: TaskFailure?

    enum CodingKeys: String, CodingKey {
        case status
        case modelURLs = "model_urls"
        case taskError = "task_error"
    }
}

private struct TaskFailure: Decodable, Sendable {
    let message: String?
}

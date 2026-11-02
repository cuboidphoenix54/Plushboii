import AppKit
import CoreImage
import CoreML
import ModelIO
import SceneKit
import Vision

/// On-device image-to-3D: Vision foreground isolation, Core Image framing into the model's input buffer,
/// Core ML inference on the Neural Engine/GPU, then a ModelIO bridge into SceneKit. No network, no subprocesses.
@MainActor
final class CoreMLMeshProvider: MeshIngestionService {
    private let imageSource: ImageSource

    private enum ImageSource {
        case url(URL)
        case image(NSImage)
    }

    let sourceFormat = "triposr"
    let suggestedName = "Local Generated Mesh"

    init(imageURL: URL) {
        imageSource = .url(imageURL)
    }

    init(image: NSImage) {
        imageSource = .image(image)
    }

    func ingest() async throws -> IngestedMesh {
        switch imageSource {
        case .image(let image):
            return try await ingest(image: image)
        case .url(let url):
            let data = try await offMainActor { try Self.readData(at: url) }
            guard let image = NSImage(data: data) else { throw LocalInferenceError.imageUnreadable }
            return try await ingest(image: image)
        }
    }

    /// Generates a validated mesh from a 2D image. Nothing is returned unless `MeshSchemaEnforcer` passes.
    func ingest(image: NSImage) async throws -> IngestedMesh {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw LocalInferenceError.imageUnreadable
        }
        let mesh = try await LocalLRMPipeline.generate(from: cgImage)
        try Task.checkCancellation()
        let render = try await MeshRenderData.prepare(mesh)
        return (try render.makeModelIONode(), mesh)
    }

    private nonisolated static func readData(at url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw LocalInferenceError.imageUnreadable
        }
    }
}

/// Runs off the main actor; the non-`Sendable` pixel buffer and model arrays never leave this type.
/// The bundled model (`TripoSR_DensityPipeline`, built by `convert_density_to_coreml.py`) maps the image to the
/// NeRF log-density `[1,R,R,R]` (layout z,y,x; x fastest). The grid span, resolution and iso level come from its metadata.
enum LocalLRMPipeline {
    static let modelName = "TripoSR_DensityPipeline"
    static let side = 512
    /// Neutral colour the subject is composited over after background removal.
    static let backgroundGray: CGFloat = 0.5
    /// Fraction of the input square the subject occupies.
    static let subjectFill: CGFloat = 0.85
    static let inputShape = [1, 3, 512, 512]

    private struct GridMetadata {
        let resolution: Int
        let radius: Double
        let isoLevel: Double
    }

    static func generate(from image: CGImage) async throws -> ImportedMesh {
        let model = try await loadModel()
        let (inputName, outputName) = try interface(of: model)
        let grid = try gridMetadata(of: model)

        let pixelBuffer = try preprocess(image)
        let input = try tensor(from: pixelBuffer)
        try Task.checkCancellation()

        let features = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: input)])
        let output = try await model.prediction(from: features)
        try Task.checkCancellation()

        guard let array = output.featureValue(for: outputName)?.multiArrayValue else {
            throw LocalInferenceError.outputNotMultiArray(outputName)
        }
        let field = try readField(array, name: outputName, grid: grid)
        return try MarchingTetrahedra.extract(field, isoLevel: Float(grid.isoLevel))
    }

    private static func gridMetadata(of model: MLModel) throws -> GridMetadata {
        let creator = model.modelDescription.metadata[MLModelMetadataKey.creatorDefinedKey] as? [String: String] ?? [:]
        guard let resolution = creator["plushboii.grid_resolution"].flatMap({ Int($0) }), resolution >= 2,
              let radius = creator["plushboii.grid_radius"].flatMap({ Double($0) }), radius.isFinite, radius > 0,
              let iso = creator["plushboii.iso_level"].flatMap({ Double($0) }), iso.isFinite
        else { throw LocalInferenceError.modelInterfaceMismatch("missing plushboii.grid_* metadata") }
        return GridMetadata(resolution: resolution, radius: radius, isoLevel: iso)
    }

    private static func loadModel() async throws -> MLModel {
        guard let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") else {
            throw LocalInferenceError.modelNotBundled
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        return try await MLModel.load(contentsOf: url, configuration: configuration)
    }

    /// Verifies the model still has the single `[1,3,512,512]` input and single 4-D output this code was written for.
    private static func interface(of model: MLModel) throws -> (input: String, output: String) {
        let description = model.modelDescription
        guard description.inputDescriptionsByName.count == 1, let (inName, inDesc) = description.inputDescriptionsByName.first,
              inDesc.type == .multiArray, inDesc.multiArrayConstraint?.shape.map(\.intValue) == inputShape
        else { throw LocalInferenceError.modelInterfaceMismatch("expected one MultiArray input of shape \(inputShape)") }
        guard description.outputDescriptionsByName.count == 1, let (outName, outDesc) = description.outputDescriptionsByName.first,
              outDesc.type == .multiArray, outDesc.multiArrayConstraint?.shape.count == 4
        else { throw LocalInferenceError.modelInterfaceMismatch("expected one 4-D MultiArray output") }
        return (inName, outName)
    }

    /// Vision isolates the subject; Core Image crops, scales and centres it into a 512x512 BGRA `CVPixelBuffer`.
    private static func preprocess(_ image: CGImage) throws -> CVPixelBuffer {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw LocalInferenceError.noSubjectFound
        }
        let masked = try observation.generateMaskedImage(
            ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: true
        )

        let subject = CIImage(cvPixelBuffer: masked)
        let extent = subject.extent
        guard extent.width > 0, extent.height > 0 else { throw LocalInferenceError.noSubjectFound }
        let target = CGFloat(side)
        let scale = target * subjectFill / max(extent.width, extent.height)
        let placed = subject
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: (target - extent.width * scale) / 2, y: (target - extent.height * scale) / 2))

        let bounds = CGRect(x: 0, y: 0, width: target, height: target)
        let background = CIImage(color: CIColor(red: backgroundGray, green: backgroundGray, blue: backgroundGray)).cropped(to: bounds)
        let composed = placed.composited(over: background)

        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        guard CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer
        else { throw LocalInferenceError.pixelBufferFailed }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        CIContext(options: [.workingColorSpace: colorSpace as Any]).render(composed, to: buffer, bounds: bounds, colorSpace: colorSpace)
        return buffer
    }

    /// The model takes a planar Float16 RGB tensor in 0...1, so the BGRA buffer is unpacked into `[1,3,512,512]`.
    private static func tensor(from buffer: CVPixelBuffer) throws -> MLMultiArray {
        guard CVPixelBufferGetWidth(buffer) == side, CVPixelBufferGetHeight(buffer) == side else {
            throw LocalInferenceError.pixelBufferFailed
        }
        let array = try MLMultiArray(shape: inputShape.map { NSNumber(value: $0) }, dataType: .float16)
        let strides = array.strides.map(\.intValue)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw LocalInferenceError.pixelBufferFailed }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let source = base.assumingMemoryBound(to: UInt8.self)
        let destination = array.dataPointer.assumingMemoryBound(to: Float16.self)
        for y in 0..<side {
            let row = source + y * bytesPerRow
            for x in 0..<side {
                let pixel = row + x * 4
                let offset = y * strides[2] + x * strides[3]
                destination[offset] = Float16(Float(pixel[2]) / 255)
                destination[strides[1] + offset] = Float16(Float(pixel[1]) / 255)
                destination[2 * strides[1] + offset] = Float16(Float(pixel[0]) / 255)
            }
        }
        return array
    }

    private static func readField(_ array: MLMultiArray, name: String, grid: GridMetadata) throws -> ScalarField {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        let n = grid.resolution
        guard shape == [1, n, n, n], strides.count == 4, strides.allSatisfy({ $0 > 0 }) else {
            throw LocalInferenceError.invalidTensorShape(name: name, shape: shape)
        }
        let lastElement = (n - 1) * (strides[1] + strides[2] + strides[3])
        guard array.count == n * n * n, lastElement < array.count else {
            throw LocalInferenceError.tensorOutOfBounds(name)
        }
        var values = [Float](repeating: 0, count: n * n * n)

        func copy<T: BinaryFloatingPoint>(_ source: UnsafePointer<T>) {
            var out = 0
            for z in 0..<n { for y in 0..<n {
                let rowBase = z * strides[1] + y * strides[2]
                for x in 0..<n {
                    values[out] = Float(source[rowBase + x * strides[3]])
                    out += 1
                }
            } }
        }
        switch array.dataType {
        case .float16: copy(array.dataPointer.assumingMemoryBound(to: Float16.self))
        case .float32: copy(array.dataPointer.assumingMemoryBound(to: Float.self))
        default: throw LocalInferenceError.unsupportedTensorType(name)
        }
        guard values.allSatisfy(\.isFinite) else { throw LocalInferenceError.unsupportedTensorType(name) }
        return try ScalarField(resolution: n, values: values, origin: SIMD3(repeating: -grid.radius),
                               spacing: 2 * grid.radius / Double(n - 1))
    }
}

extension MeshRenderData {
    /// Bridges the validated buffers through ModelIO (`MDLMesh`) into a SceneKit node. The interleaved layout keeps
    /// vertex `i` equal to `mesh.vertices[i]`; a changed vertex count is rejected rather than accepted.
    @MainActor
    func makeModelIONode() throws -> SCNNode {
        let floats = MemoryLayout<Float>.size
        var interleaved = [Float](repeating: 0, count: vertexCount * 6)
        positions.withUnsafeBytes { p in
            normals.withUnsafeBytes { n in
                let p = p.bindMemory(to: Float.self)
                let n = n.bindMemory(to: Float.self)
                for i in 0..<vertexCount {
                    for k in 0..<3 {
                        interleaved[i * 6 + k] = p[i * 3 + k]
                        interleaved[i * 6 + 3 + k] = n[i * 3 + k]
                    }
                }
            }
        }

        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        descriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 3 * floats, bufferIndex: 0)
        let layout = MDLVertexBufferLayout()
        layout.stride = 6 * floats
        descriptor.layouts[0] = layout

        let vertexBuffer = MDLMeshBufferData(type: .vertex, data: interleaved.withUnsafeBytes { Data($0) })
        let indexBuffer = MDLMeshBufferData(type: .index, data: indices)
        let submesh = MDLSubmesh(
            indexBuffer: indexBuffer, indexCount: triangleCount * 3, indexType: .uInt32,
            geometryType: .triangles, material: nil
        )
        let mesh = MDLMesh(vertexBuffer: vertexBuffer, vertexCount: vertexCount, descriptor: descriptor, submeshes: [submesh])

        // The SceneKit/ModelIO convenience initialisers are not importable here, so the geometry is rebuilt from
        // the MDLMesh's own buffers.
        guard
            let positionData = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3),
            let normalData = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal, as: .float3),
            mesh.vertexCount == vertexCount,
            let meshSubmesh = (mesh.submeshes?.firstObject as? MDLSubmesh),
            meshSubmesh.indexCount == triangleCount * 3,
            meshSubmesh.indexType == .uInt32
        else { throw LocalInferenceError.modelIOBridgeMismatch }

        func source(_ data: MDLVertexAttributeData, _ semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
            SCNGeometrySource(
                data: Data(bytes: data.dataStart, count: data.stride * vertexCount), semantic: semantic,
                vectorCount: vertexCount, usesFloatComponents: true, componentsPerVector: 3,
                bytesPerComponent: floats, dataOffset: 0, dataStride: data.stride
            )
        }
        let indexMap = meshSubmesh.indexBuffer.map()
        let element = SCNGeometryElement(
            data: Data(bytes: indexMap.bytes, count: meshSubmesh.indexCount * MemoryLayout<UInt32>.size),
            primitiveType: .triangles, primitiveCount: triangleCount, bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geometry = SCNGeometry(
            sources: [source(positionData, .vertex), source(normalData, .normal)], elements: [element]
        )
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.systemTeal
        material.isDoubleSided = true
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }
}

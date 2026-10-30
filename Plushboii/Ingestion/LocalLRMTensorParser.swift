import CoreML
import Foundation

/// Names of the Core ML outputs that carry geometry. These are an interface contract with the bundled
/// `LocalLRM.mlpackage`; `LocalLRMTensorParser` checks them against the real model description and fails loudly.
struct LocalLRMOutputSchema: Sendable, Equatable {
    var verticesName = "vertices"
    var facesName = "faces"
}

enum LocalInferenceError: LocalizedError, Equatable {
    case modelNotBundled
    case modelHasNoImageInput
    case missingOutput(expected: String, available: [String])
    case outputNotMultiArray(String)
    case invalidTensorShape(name: String, shape: [Int])
    case unsupportedTensorType(String)
    case tensorOutOfBounds(String)
    case invalidFaceIndex
    case imageUnreadable
    case noSubjectFound
    case pixelBufferFailed
    case modelIOBridgeMismatch
    case densityDecoderMissing
    case modelInterfaceMismatch(String)

    var errorDescription: String? {
        switch self {
        case .modelNotBundled:
            "TripoSR_Pipeline is not bundled with the app. Add TripoSR_Pipeline.mlpackage to the Plushboii target's Compile Sources."
        case .modelHasNoImageInput:
            "LocalLRM does not expose exactly one image input."
        case .missingOutput(let expected, let available):
            "LocalLRM has no MultiArray output named \"\(expected)\" (available: \(available.sorted().joined(separator: ", ")))."
        case .outputNotMultiArray(let name):
            "LocalLRM output \"\(name)\" is not a MultiArray."
        case .invalidTensorShape(let name, let shape):
            "LocalLRM output \"\(name)\" has shape \(shape), expected [N, 3] (leading dimensions of size 1 are allowed)."
        case .unsupportedTensorType(let name):
            "LocalLRM output \"\(name)\" uses an unsupported element type."
        case .tensorOutOfBounds(let name):
            "LocalLRM output \"\(name)\" is smaller than its declared shape and strides."
        case .invalidFaceIndex:
            "LocalLRM produced a face index that is not a non-negative whole number."
        case .imageUnreadable:
            "The selected file could not be decoded as an image."
        case .noSubjectFound:
            "No foreground subject was found in the image."
        case .pixelBufferFailed:
            "The preprocessed image could not be rendered into the model's input buffer."
        case .densityDecoderMissing:
            "TripoSR_Pipeline outputs a raw 3x1024x32x32 triplane. Converting it to a surface needs TripoSR's NeRF density decoder, which is not in the model package and has not been provided."
        case .modelInterfaceMismatch(let detail):
            "TripoSR_Pipeline does not match the interface this app was written for: \(detail)."
        case .modelIOBridgeMismatch:
            "The ModelIO conversion changed the vertex layout, so seam picks would no longer match the mesh."
        }
    }
}

/// Converts Core ML `MLMultiArray` outputs into the app's vertex/face schema without per-element boxing.
enum LocalLRMTensorParser {
    /// Reads `[N, 3]` (optionally with leading size-1 dimensions) honouring the array's real strides.
    static func parse(vertices: MLMultiArray, faces: MLMultiArray, schema: LocalLRMOutputSchema = .init()) throws -> ImportedMesh {
        let positions = try readMatrix(vertices, name: schema.verticesName, rowLimit: MeshSchemaEnforcer.maximumVertices)
        let indices = try readMatrix(faces, name: schema.facesName, rowLimit: MeshSchemaEnforcer.maximumTriangles)

        var meshVertices = [MeshVertex]()
        meshVertices.reserveCapacity(positions.count / 3)
        var i = 0
        while i < positions.count {
            meshVertices.append(MeshVertex(x: positions[i], y: positions[i + 1], z: positions[i + 2]))
            i += 3
        }

        var triangles = [MeshTriangle]()
        triangles.reserveCapacity(indices.count / 3)
        i = 0
        while i < indices.count {
            guard let a = Int(exactly: indices[i]), let b = Int(exactly: indices[i + 1]), let c = Int(exactly: indices[i + 2]),
                  a >= 0, b >= 0, c >= 0
            else { throw LocalInferenceError.invalidFaceIndex }
            triangles.append(MeshTriangle(a: a, b: b, c: c))
            i += 3
        }
        return try MeshSchemaEnforcer.validate(ImportedMesh(vertices: meshVertices, triangles: triangles))
    }

    /// Row-major flattened `rows * 3` values.
    private static func readMatrix(_ array: MLMultiArray, name: String, rowLimit: Int) throws -> [Double] {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        guard shape.count >= 2, shape.last == 3, shape.allSatisfy({ $0 > 0 }), strides.count == shape.count else {
            throw LocalInferenceError.invalidTensorShape(name: name, shape: shape)
        }
        let leading = shape.dropLast().enumerated().filter { $0.element > 1 }
        guard leading.count <= 1 else { throw LocalInferenceError.invalidTensorShape(name: name, shape: shape) }
        let rows = leading.first?.element ?? 1
        let rowStride = leading.first.map { strides[$0.offset] } ?? 0
        let columnStride = strides[strides.count - 1]
        guard rows <= rowLimit, rowStride >= 0, columnStride > 0 else {
            throw LocalInferenceError.invalidTensorShape(name: name, shape: shape)
        }
        let lastElement = (rows - 1) * rowStride + 2 * columnStride

        var result = [Double](repeating: 0, count: rows * 3)
        try array.withUnsafeBytes { raw in
            switch array.dataType {
            case .float32:
                try gather(raw.bindMemory(to: Float.self), rows, rowStride, columnStride, lastElement, name, &result) { Double($0) }
            case .double:
                try gather(raw.bindMemory(to: Double.self), rows, rowStride, columnStride, lastElement, name, &result) { $0 }
            case .int32:
                try gather(raw.bindMemory(to: Int32.self), rows, rowStride, columnStride, lastElement, name, &result) { Double($0) }
            case .float16:
                #if arch(arm64)
                try gather(raw.bindMemory(to: Float16.self), rows, rowStride, columnStride, lastElement, name, &result) { Double($0) }
                #else
                throw LocalInferenceError.unsupportedTensorType(name)
                #endif
            default:
                throw LocalInferenceError.unsupportedTensorType(name)
            }
        }
        return result
    }

    @inline(__always)
    private static func gather<T>(
        _ source: UnsafeBufferPointer<T>, _ rows: Int, _ rowStride: Int, _ columnStride: Int, _ lastElement: Int,
        _ name: String, _ result: inout [Double], convert: (T) -> Double
    ) throws {
        guard lastElement < source.count else { throw LocalInferenceError.tensorOutOfBounds(name) }
        for row in 0..<rows {
            let base = row * rowStride
            result[row * 3] = convert(source[base])
            result[row * 3 + 1] = convert(source[base + columnStride])
            result[row * 3 + 2] = convert(source[base + 2 * columnStride])
        }
    }
}

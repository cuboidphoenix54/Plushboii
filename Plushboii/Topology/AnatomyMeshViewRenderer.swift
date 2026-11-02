import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum AnatomyMeshViewRenderer {
    enum View: String, CaseIterable {
        case front
        case side
        case top

        var direction: Vec3 {
            switch self {
            case .front: Vec3(0, 0, 1)
            case .side: Vec3(1, 0, 0)
            case .top: Vec3(0, 1, 0)
            }
        }

        func project(_ point: Vec3) -> (horizontal: Double, vertical: Double, depth: Double) {
            switch self {
            case .front: (point.x, point.y, point.z)
            case .side: (-point.z, point.y, point.x)
            case .top: (point.x, -point.z, point.y)
            }
        }
    }

    static func render(
        positions: [Vec3],
        triangles: [Int32],
        size: Int = 256
    ) throws -> [Data] {
        guard positions.count >= 3, triangles.count >= 3, triangles.count.isMultiple(of: 3),
              positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              triangles.allSatisfy({ $0 >= 0 && Int($0) < positions.count }),
              (64...1024).contains(size)
        else {
            throw FlatteningError.invalidMesh("the mesh cannot be rendered as registered anatomy views")
        }

        return try View.allCases.map { view in
            try render(view: view, positions: positions, triangles: triangles, size: size)
        }
    }

    private static func render(
        view: View,
        positions: [Vec3],
        triangles: [Int32],
        size: Int
    ) throws -> Data {
        let projected = positions.map(view.project)
        guard let minH = projected.map(\.horizontal).min(),
              let maxH = projected.map(\.horizontal).max(),
              let minV = projected.map(\.vertical).min(),
              let maxV = projected.map(\.vertical).max()
        else {
            throw FlatteningError.invalidMesh("the mesh view has no projected vertices")
        }
        let extent = max(maxH - minH, maxV - minV)
        guard extent.isFinite, extent > 0 else {
            throw FlatteningError.invalidMesh("the mesh has no visible extent in its \(view.rawValue) view")
        }
        let margin = Double(size) * 0.08
        let scale = (Double(size) - 2 * margin) / extent
        let centerH = (minH + maxH) * 0.5
        let centerV = (minV + maxV) * 0.5
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        var depthBuffer = [Double](repeating: -.infinity, count: size * size)

        for offset in stride(from: 0, to: triangles.count, by: 3) {
            let indices = (0..<3).map { Int(triangles[offset + $0]) }
            let points = indices.map { projected[$0] }
            let screen = points.map { point in
                (
                    x: (point.horizontal - centerH) * scale + Double(size) * 0.5,
                    y: Double(size) * 0.5 - (point.vertical - centerV) * scale,
                    depth: point.depth
                )
            }
            let area = edge(screen[0], screen[1], screen[2].x, screen[2].y)
            guard area.isFinite, abs(area) > 1e-10 else { continue }
            let minX = max(0, Int(floor(screen.map(\.x).min() ?? 0)))
            let maxX = min(size - 1, Int(ceil(screen.map(\.x).max() ?? 0)))
            let minY = max(0, Int(floor(screen.map(\.y).min() ?? 0)))
            let maxY = min(size - 1, Int(ceil(screen.map(\.y).max() ?? 0)))
            guard minX <= maxX, minY <= maxY else { continue }

            let a = positions[indices[0]]
            let b = positions[indices[1]]
            let c = positions[indices[2]]
            let faceNormal = vcross(b - a, c - a)
            let normalLength = vlength(faceNormal)
            guard normalLength.isFinite, normalLength > 0 else { continue }
            let brightness = UInt8((80 + 150 * abs(vdot(faceNormal / normalLength, view.direction))).rounded())

            for y in minY...maxY {
                for x in minX...maxX {
                    let px = Double(x) + 0.5
                    let py = Double(y) + 0.5
                    let w0 = edge(screen[1], screen[2], px, py) / area
                    let w1 = edge(screen[2], screen[0], px, py) / area
                    let w2 = edge(screen[0], screen[1], px, py) / area
                    guard w0 >= -1e-9, w1 >= -1e-9, w2 >= -1e-9 else { continue }
                    let fragmentDepth = w0 * screen[0].depth + w1 * screen[1].depth + w2 * screen[2].depth
                    let pixelIndex = y * size + x
                    guard fragmentDepth > depthBuffer[pixelIndex] else { continue }
                    depthBuffer[pixelIndex] = fragmentDepth
                    let byte = pixelIndex * 4
                    pixels[byte] = UInt8(Double(brightness) * 0.72)
                    pixels[byte + 1] = UInt8(Double(brightness) * 0.92)
                    pixels[byte + 2] = brightness
                    pixels[byte + 3] = 255
                }
            }
        }

        let pixelData = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: pixelData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                  width: size,
                  height: size,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: size * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else {
            throw FlatteningError.invalidMesh("the \(view.rawValue) view could not be encoded")
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw FlatteningError.invalidMesh("the \(view.rawValue) view could not be encoded")
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.85
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw FlatteningError.invalidMesh("the \(view.rawValue) view could not be encoded")
        }
        return output as Data
    }

    private static func edge(
        _ a: (x: Double, y: Double, depth: Double),
        _ b: (x: Double, y: Double, depth: Double),
        _ x: Double,
        _ y: Double
    ) -> Double {
        (x - a.x) * (b.y - a.y) - (y - a.y) * (b.x - a.x)
    }
}

import AppKit
import SceneKit
import SwiftUI
import simd

struct MeshSceneView: NSViewRepresentable {
    let mesh: MeshTopology?
    /// Node produced by a `MeshIngestionService`; used instead of rebuilding geometry when it matches `mesh`.
    let ingestedNode: SCNNode?
    let seams: [SeamPath]
    let isPickingEnabled: Bool
    let resetToken: Int
    let onPick: @MainActor (Int, Bool) -> Void
    let onUndo: @MainActor () -> Void

    func makeNSView(context: Context) -> TrackpadSCNView {
        let view = TrackpadSCNView(frame: .zero)
        view.configure()
        return view
    }

    func updateNSView(_ view: TrackpadSCNView, context: Context) {
        view.onPick = onPick
        view.onUndo = onUndo
        view.isPickingEnabled = isPickingEnabled
        view.apply(mesh: mesh, seams: seams, ingestedNode: ingestedNode)
        view.applyResetToken(resetToken)
    }
}

@MainActor
final class TrackpadSCNView: SCNView {
    var onPick: (@MainActor (Int, Bool) -> Void)?
    var onUndo: (@MainActor () -> Void)?
    var isPickingEnabled = false {
        didSet {
            if oldValue != isPickingEnabled { window?.invalidateCursorRects(for: self) }
        }
    }

    private let panNode = SCNNode()
    private let orbitNode = SCNNode()
    private let overlayNode = SCNNode()
    private let cameraNode = SCNNode()
    private var meshNode: SCNNode?
    private var ingestedNode: SCNNode?
    private var mesh: MeshTopology?
    private var appliedSeams: [SeamPath] = []
    private var distance = 3.0
    private var lastResetToken = 0
    private var mouseDownPoint = CGPoint.zero
    private var didDrag = false

    override var acceptsFirstResponder: Bool { true }

    func configure() {
        backgroundColor = .windowBackgroundColor
        antialiasingMode = .multisampling4X
        allowsCameraControl = false

        let scene = SCNScene()
        scene.rootNode.addChildNode(panNode)
        panNode.addChildNode(orbitNode)
        orbitNode.addChildNode(overlayNode)

        let camera = SCNCamera()
        camera.fieldOfView = 45
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 450
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let headlight = SCNLight()
        headlight.type = .directional
        headlight.intensity = 900
        let headlightNode = SCNNode()
        headlightNode.light = headlight
        cameraNode.addChildNode(headlightNode)

        self.scene = scene
        pointOfView = cameraNode
        updateCamera()
    }

    func apply(mesh newMesh: MeshTopology?, seams: [SeamPath], ingestedNode node: SCNNode?) {
        ingestedNode = node
        var overlayDirty = seams != appliedSeams
        if newMesh?.id != mesh?.id {
            mesh = newMesh
            rebuildMeshNode()
            resetCamera()
            overlayDirty = true
        }
        if overlayDirty {
            appliedSeams = seams
            rebuildOverlay(seams)
        }
    }

    func applyResetToken(_ token: Int) {
        guard token != lastResetToken else { return }
        lastResetToken = token
        resetCamera()
    }

    // MARK: Scene construction

    private func rebuildMeshNode() {
        meshNode?.removeFromParentNode()
        meshNode = nil
        guard let mesh else { return }

        // The ingested node shares vertex numbering with the stored mesh, so picks still index correctly.
        if let node = ingestedNode,
           node.geometry?.sources(for: .vertex).first?.vectorCount == mesh.positions.count {
            node.removeFromParentNode()
            orbitNode.addChildNode(node)
            meshNode = node
            return
        }

        let vertices = mesh.positions.map { SCNVector3(x: CGFloat($0.x), y: CGFloat($0.y), z: CGFloat($0.z)) }
        let normals = mesh.normals.map { SCNVector3(x: CGFloat($0.x), y: CGFloat($0.y), z: CGFloat($0.z)) }
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
            elements: [SCNGeometryElement(indices: mesh.triangles, primitiveType: .triangles)]
        )
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.systemTeal
        material.isDoubleSided = true
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        orbitNode.addChildNode(node)
        meshNode = node
    }

    private func rebuildOverlay(_ seams: [SeamPath]) {
        overlayNode.childNodes.forEach { $0.removeFromParentNode() }
        guard let mesh else { return }

        // Lift the overlay slightly along the normals to avoid z-fighting with the surface.
        let lift = Float(mesh.radius * 0.003)
        func lifted(_ vertex: Int) -> SCNVector3 {
            let p = mesh.positions[vertex]
            let n = mesh.normals[vertex]
            return SCNVector3(
                x: CGFloat(Float(p.x) + n.x * lift),
                y: CGFloat(Float(p.y) + n.y * lift),
                z: CGFloat(Float(p.z) + n.z * lift)
            )
        }

        let lineMaterial = SCNMaterial()
        lineMaterial.lightingModel = .constant
        lineMaterial.diffuse.contents = NSColor.systemOrange
        let markerMaterial = SCNMaterial()
        markerMaterial.lightingModel = .constant
        markerMaterial.diffuse.contents = NSColor.systemRed
        let markerGeometry = SCNSphere(radius: CGFloat(mesh.radius * 0.012))
        markerGeometry.materials = [markerMaterial]

        for seam in seams {
            if seam.vertices.count >= 2 {
                let points = seam.vertices.map(lifted)
                var indices: [Int32] = []
                indices.reserveCapacity((points.count - 1) * 2)
                for i in 0..<(points.count - 1) {
                    indices.append(Int32(i))
                    indices.append(Int32(i + 1))
                }
                let geometry = SCNGeometry(
                    sources: [SCNGeometrySource(vertices: points)],
                    elements: [SCNGeometryElement(indices: indices, primitiveType: .line)]
                )
                geometry.materials = [lineMaterial]
                overlayNode.addChildNode(SCNNode(geometry: geometry))
            }
            for anchor in seam.anchors {
                let marker = SCNNode(geometry: markerGeometry)
                marker.position = lifted(anchor)
                overlayNode.addChildNode(marker)
            }
        }
    }

    // MARK: Camera

    private func resetCamera() {
        panNode.simdPosition = .zero
        orbitNode.simdOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        distance = max(mesh?.radius ?? 1, 1e-6) * 2.8
        updateCamera()
    }

    private func updateCamera() {
        let radius = max(mesh?.radius ?? 1, 1e-6)
        distance = min(max(distance, radius * 0.3), radius * 20)
        cameraNode.simdPosition = SIMD3<Float>(0, 0, Float(distance))
        cameraNode.camera?.zNear = radius * 0.01
        cameraNode.camera?.zFar = distance * 4 + radius * 10
    }

    private func pan(dx: Double, dy: Double) {
        let fieldOfView = Double(cameraNode.camera?.fieldOfView ?? 45) * .pi / 180
        let unitsPerPoint = 2 * distance * tan(fieldOfView / 2) / max(Double(bounds.height), 1)
        var position = panNode.simdPosition
        position.x += Float(dx * unitsPerPoint)
        position.y -= Float(dy * unitsPerPoint)
        panNode.simdPosition = position
    }

    private func zoom(by magnification: Double) {
        distance /= max(1 + magnification, 0.05)
        updateCamera()
    }

    private func orbit(dx: Double, dy: Double) {
        let sensitivity = 0.008
        let yaw = simd_quatf(angle: Float(dx * sensitivity), axis: SIMD3<Float>(0, 1, 0))
        let pitch = simd_quatf(angle: Float(dy * sensitivity), axis: SIMD3<Float>(1, 0, 0))
        orbitNode.simdOrientation = simd_normalize(yaw * pitch * orbitNode.simdOrientation)
    }

    // MARK: Trackpad and mouse input

    override func scrollWheel(with event: NSEvent) {
        guard mesh != nil else { return }
        if event.hasPreciseScrollingDeltas {
            pan(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY))
        } else {
            zoom(by: Double(event.scrollingDeltaY) * 0.05)
        }
    }

    override func magnify(with event: NSEvent) {
        guard mesh != nil else { return }
        zoom(by: Double(event.magnification))
    }

    override func rotate(with event: NSEvent) {
        guard mesh != nil else { return }
        let roll = simd_quatf(angle: event.rotation * .pi / 180, axis: SIMD3<Float>(0, 0, 1))
        orbitNode.simdOrientation = simd_normalize(roll * orbitNode.simdOrientation)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard mesh != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !didDrag, hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > 4 {
            didDrag = true
        }
        guard didDrag else { return }
        if event.modifierFlags.contains(.option) {
            pan(dx: Double(event.deltaX), dy: Double(event.deltaY))
        } else {
            orbit(dx: Double(event.deltaX), dy: Double(event.deltaY))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard !didDrag else { return }
        if isPickingEnabled {
            pick(at: convert(event.locationInWindow, from: nil), startingNewSeam: event.modifierFlags.contains(.shift))
        } else if event.clickCount == 2 {
            resetCamera()
        }
    }

    override func keyDown(with event: NSEvent) {
        if isPickingEnabled, event.keyCode == 51 || event.keyCode == 117 {
            onUndo?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isPickingEnabled ? .crosshair : .arrow)
    }

    // MARK: Picking

    private func pick(at point: CGPoint, startingNewSeam: Bool) {
        guard let meshNode, let mesh else { return }
        let hits = hitTest(point, options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .rootNode: meshNode
        ])
        guard let hit = hits.first, hit.node === meshNode else { return }

        let base = hit.faceIndex * 3
        guard base >= 0, base + 2 < mesh.triangles.count else { return }
        let local = SIMD3<Double>(
            Double(hit.localCoordinates.x),
            Double(hit.localCoordinates.y),
            Double(hit.localCoordinates.z)
        )
        let corners = (0..<3).map { Int(mesh.triangles[base + $0]) }
        guard let nearest = corners.min(by: {
            simd_distance_squared(mesh.positions[$0], local) < simd_distance_squared(mesh.positions[$1], local)
        }) else {
            return
        }
        onPick?(nearest, startingNewSeam)
    }
}

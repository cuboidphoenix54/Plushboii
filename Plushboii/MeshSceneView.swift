import AppKit
import SceneKit
import SwiftUI
import simd

struct MeshSceneView: NSViewRepresentable {
    let mesh: MeshTopology?
    /// Node produced by a `MeshIngestionService`; used instead of rebuilding geometry when it matches `mesh`.
    let ingestedNode: SCNNode?
    let seams: [SeamPath]
    let suggestedSeams: [SeamSuggestion]
    let previewComponents: [MeshComponent]?
    let previewToken: Int
    /// Per-vertex stretch severity (0...1) to paint as a white-to-red heatmap; nil shows the plain surface.
    var heatSeverity: [Double]? = nil
    var heatToken = 0
    var joints: [AnatomicalJoint] = []
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
        view.apply(
            mesh: mesh,
            seams: seams,
            suggestedSeams: suggestedSeams,
            previewComponents: previewComponents,
            previewToken: previewToken,
            ingestedNode: ingestedNode
        )
        view.applyHeat(heatSeverity, token: heatToken)
        view.applyJoints(joints)
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
    private let previewNode = SCNNode()
    private let heatNode = SCNNode()
    private let jointNode = SCNNode()
    private var appliedJoints: [AnatomicalJoint] = []
    private var lastHeatToken = -1
    private let cameraNode = SCNNode()
    private var meshNode: SCNNode?
    private var ingestedNode: SCNNode?
    private var mesh: MeshTopology?
    private var appliedSeams: [SeamPath] = []
    private var appliedSuggestions: [SeamSuggestion] = []
    private var distance = 3.0
    private var lastResetToken = 0
    private var lastPreviewToken = -1
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
        orbitNode.addChildNode(jointNode)
        orbitNode.addChildNode(previewNode)
        orbitNode.addChildNode(heatNode)

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

    func apply(
        mesh newMesh: MeshTopology?,
        seams: [SeamPath],
        suggestedSeams: [SeamSuggestion],
        previewComponents: [MeshComponent]?,
        previewToken: Int,
        ingestedNode node: SCNNode?
    ) {
        ingestedNode = node
        var overlayDirty = seams != appliedSeams || suggestedSeams != appliedSuggestions
        var meshChanged = false
        if newMesh?.id != mesh?.id {
            mesh = newMesh
            rebuildMeshNode()
            resetCamera()
            overlayDirty = true
            meshChanged = true
        }
        if previewToken != lastPreviewToken || meshChanged {
            lastPreviewToken = previewToken
            rebuildPreview(previewComponents)
        }
        if overlayDirty {
            appliedSeams = seams
            appliedSuggestions = suggestedSeams
            rebuildOverlay(seams, suggestions: suggestedSeams)
        }
    }

    /// Draws each joint as a red anchor and a translucent disc showing the plane its cut will follow.
    func applyJoints(_ joints: [AnatomicalJoint]) {
        guard joints != appliedJoints else { return }
        appliedJoints = joints
        jointNode.childNodes.forEach { $0.removeFromParentNode() }
        guard let mesh else { return }
        let radius = CGFloat(mesh.radius * 0.28)
        for joint in joints {
            let center = SCNVector3(x: CGFloat(joint.position.x), y: CGFloat(joint.position.y), z: CGFloat(joint.position.z))
            let disc = SCNCylinder(radius: radius, height: radius * 0.02)
            let discMaterial = SCNMaterial()
            discMaterial.lightingModel = .constant
            discMaterial.diffuse.contents = NSColor.systemOrange.withAlphaComponent(0.35)
            discMaterial.isDoubleSided = true
            discMaterial.writesToDepthBuffer = false
            disc.materials = [discMaterial]
            let discNode = SCNNode(geometry: disc)
            discNode.position = center
            let direction = simd_normalize(SIMD3<Float>(Float(joint.direction.x), Float(joint.direction.y), Float(joint.direction.z)))
            if direction.x.isFinite { discNode.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: direction) }
            jointNode.addChildNode(discNode)

            let anchor = SCNSphere(radius: radius * 0.07)
            let anchorMaterial = SCNMaterial()
            anchorMaterial.lightingModel = .constant
            anchorMaterial.diffuse.contents = NSColor.systemRed
            anchor.materials = [anchorMaterial]
            let anchorNode = SCNNode(geometry: anchor)
            anchorNode.position = center
            jointNode.addChildNode(anchorNode)
        }
    }

    func applyHeat(_ severity: [Double]?, token: Int) {
        guard token != lastHeatToken else { return }
        lastHeatToken = token
        heatNode.childNodes.forEach { $0.removeFromParentNode() }
        guard let mesh, let severity, severity.count == mesh.positions.count else {
            if previewNode.childNodes.isEmpty { meshNode?.isHidden = false }
            return
        }
        let vertices = mesh.positions.map { SCNVector3(x: CGFloat($0.x), y: CGFloat($0.y), z: CGFloat($0.z)) }
        let normals = mesh.normals.map { SCNVector3(x: CGFloat($0.x), y: CGFloat($0.y), z: CGFloat($0.z)) }
        var colors = [Float]()
        colors.reserveCapacity(severity.count * 4)
        for value in severity {
            let c = PatternQualityMap.heatColor(value)
            colors.append(contentsOf: [Float(c.red), Float(c.green), Float(c.blue), 1])
        }
        let colorSource = SCNGeometrySource(
            data: colors.withUnsafeBytes { Data($0) },
            semantic: .color,
            vectorCount: severity.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 4
        )
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals), colorSource],
            elements: [SCNGeometryElement(indices: mesh.triangles, primitiveType: .triangles)]
        )
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.white
        material.isDoubleSided = true
        geometry.materials = [material]
        heatNode.addChildNode(SCNNode(geometry: geometry))
        meshNode?.isHidden = true
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

    private func rebuildOverlay(_ seams: [SeamPath], suggestions: [SeamSuggestion]) {
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
        let suggestionMaterial = SCNMaterial()
        suggestionMaterial.lightingModel = .constant
        suggestionMaterial.diffuse.contents = NSColor.systemPurple
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

        for suggestion in suggestions {
            for path in suggestion.seamPaths {
                guard path.count >= 2, path.allSatisfy(mesh.positions.indices.contains) else { continue }
                let points = path.map(lifted)
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
                geometry.materials = [suggestionMaterial]
                overlayNode.addChildNode(SCNNode(geometry: geometry))
            }
        }
    }

    private func rebuildPreview(_ components: [MeshComponent]?) {
        previewNode.childNodes.forEach { $0.removeFromParentNode() }
        guard let components else {
            meshNode?.isHidden = false
            return
        }

        meshNode?.isHidden = true
        for (index, component) in components.enumerated() {
            let vertices = component.positions.map {
                SCNVector3(x: CGFloat($0.x), y: CGFloat($0.y), z: CGFloat($0.z))
            }
            let geometry = SCNGeometry(
                sources: [SCNGeometrySource(vertices: vertices)],
                elements: [SCNGeometryElement(indices: component.triangles, primitiveType: .triangles)]
            )
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = NSColor(
                calibratedHue: CGFloat((Double(index) * 0.61803398875).truncatingRemainder(dividingBy: 1)),
                saturation: 0.72,
                brightness: 0.88,
                alpha: 1
            )
            material.isDoubleSided = true
            geometry.materials = [material]
            previewNode.addChildNode(SCNNode(geometry: geometry))
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

import SceneKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private enum ImportKind {
    case image
    case localImage
    case model
}

private enum FabricChoice: String, CaseIterable, Identifiable {
    case none = "No fabric adjustment"
    case minky = "2-way stretch minky"
    case canvas = "Rigid canvas (darts)"

    var id: Self { self }

    var profile: FabricProfile {
        switch self {
        case .none: .none
        case .minky: .twoWayStretch(warpPercent: 50, weftPercent: 40)
        case .canvas: .rigid(maxDarts: 4)
        }
    }
}

@MainActor
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Pattern.createdAt, order: .reverse) private var patterns: [Pattern]

    @State private var selectedPatternID: UUID?
    @State private var selectedPieceID: UUID?
    @State private var apiKey = ""
    @State private var isImporting = false
    @State private var isChoosingFile = false
    @State private var fileImportKind = ImportKind.model
    @State private var ingestedNode: (pieceID: UUID, node: SCNNode)?
    @State private var ingestedMesh: (pieceID: UUID, mesh: ImportedMesh)?
    @State private var fabricChoice = FabricChoice.none
    @State private var isFlattening = false
    @State private var flattening: FlatteningResult?
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var importStatus: String?
    @State private var importProgressLabel = "Importing and validating mesh..."
    @State private var seamEditor = SeamEditorState()
    @State private var isSeamToolActive = false
    @State private var cameraResetToken = 0
    @State private var meshReloadToken = 0

    private var selectedPattern: Pattern? {
        patterns.first { $0.id == selectedPatternID }
    }

    private var selectedPiece: PatternPiece? {
        selectedPattern?.pieces.first { $0.id == selectedPieceID }
    }

    private var meshToken: String {
        guard let piece = selectedPiece else { return "none-\(meshReloadToken)" }
        return "\(piece.id)-\(piece.vertexData.count)-\(piece.faceIndexData.count)-\(meshReloadToken)"
    }

    var body: some View {
        NavigationSplitView {
            documentSidebar
        } detail: {
            detailView
        }
        .navigationTitle("Plushboii")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: createPattern) {
                    Label("New Pattern", systemImage: "plus")
                }
                .help("Create a pattern document")
                .disabled(isImporting)
            }
        }
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: fileImportKind == .model ? Self.modelTypes : [.image],
            allowsMultipleSelection: false,
            onCompletion: handleFileSelection
        )
        .alert("Operation Failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onChange(of: selectedPatternID) { _, _ in
            selectedPieceID = selectedPattern?.pieces.sorted(by: { $0.sortOrder < $1.sortOrder }).first?.id
        }
        .task(id: meshToken) {
            await seamEditor.load(piece: selectedPiece)
        }
        .onChange(of: seamEditor.seams) { _, newSeams in
            persistSeams(newSeams)
        }
    }

    private var documentSidebar: some View {
        List(selection: $selectedPatternID) {
            Section("Documents") {
                ForEach(patterns) { pattern in
                    Label(pattern.name, systemImage: "doc.text")
                        .tag(pattern.id)
                        .contextMenu {
                            Button("Delete Pattern", role: .destructive) {
                                delete(pattern)
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .disabled(isImporting)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button {
                    beginImport(.localImage)
                } label: {
                    Label("Generate from Image (Local Neural Engine)", systemImage: "cpu")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isImporting || selectedPattern == nil)
                .help("Generate a mesh from a photo on this Mac using Core ML")

                if isImporting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(importProgressLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Menu {
                    Button("Generate from Images (AI)", systemImage: "wand.and.stars") {
                        beginImport(.image)
                    }
                    Button("Select Local 3D File", systemImage: "folder") {
                        beginImport(.model)
                    }
                } label: {
                    Label("Import Model", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .menuStyle(.borderedButton)
                .controlSize(.large)
                .disabled(isImporting || selectedPattern == nil)
                .help(selectedPattern == nil ? "Select a pattern first" : "Import a 3D model into this pattern")

                HStack {
                    Button(action: createPattern) {
                        Label("New Pattern", systemImage: "plus")
                    }
                    Spacer()
                    if let selectedPattern {
                        Button(role: .destructive) {
                            delete(selectedPattern)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .help("Delete selected pattern")
                        .disabled(isImporting)
                    }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if let selectedPattern {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(selectedPattern.name)
                        .font(.title2.weight(.semibold))
                    Spacer()
                    if !selectedPattern.pieces.isEmpty {
                        Picker("Piece", selection: $selectedPieceID) {
                            ForEach(selectedPattern.pieces.sorted(by: { $0.sortOrder < $1.sortOrder })) { piece in
                                Text(piece.name).tag(Optional(piece.id))
                            }
                        }
                        .frame(maxWidth: 220)
                        .disabled(isImporting)
                    }
                    Button {
                        addPiece(to: selectedPattern)
                    } label: {
                        Label("Add Piece", systemImage: "plus")
                    }
                    .disabled(isImporting)
                }
                .padding()

                if let selectedPiece {
                    seamToolbar
                    MeshSceneView(
                        mesh: seamEditor.mesh,
                        ingestedNode: ingestedNode?.pieceID == selectedPiece.id ? ingestedNode?.node : nil,
                        seams: seamEditor.seams,
                        isPickingEnabled: isSeamToolActive && seamEditor.mesh != nil,
                        resetToken: cameraResetToken,
                        onPick: { vertex, startNew in
                            Task { await seamEditor.pick(vertex: vertex, startingNewSeam: startNew) }
                        },
                        onUndo: { seamEditor.undo() }
                    )
                    .overlay {
                        if seamEditor.mesh == nil && !seamEditor.isLoading {
                            ContentUnavailableView(
                                "No Mesh Yet",
                                systemImage: "cube.transparent",
                                description: Text(
                                    seamEditor.message ?? "Use Import Model in the sidebar to bring in a mesh."
                                )
                            )
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Pattern Pieces",
                        systemImage: "square.dashed",
                        description: Text("Add a piece, or use Import Model in the sidebar.")
                    )
                }

                HStack {
                    SecureField("Meshy API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                    if isImporting {
                        ProgressView()
                            .controlSize(.small)
                        Text(importProgressLabel)
                            .foregroundStyle(.secondary)
                    } else if let importStatus {
                        Text(importStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding()
            }
        } else {
            ContentUnavailableView(
                "Choose a Pattern",
                systemImage: "square.stack.3d.up",
                description: Text("Create or select a pattern document in the sidebar.")
            )
        }
    }

    private var seamToolbar: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $isSeamToolActive) {
                Label("Seam Tool", systemImage: "scissors")
            }
            .toggleStyle(.button)
            .disabled(seamEditor.mesh == nil)
            Button("New Seam") { seamEditor.startNewSeam() }
                .disabled(!isSeamToolActive)
            Button("Close Loop") { Task { await seamEditor.closeActiveSeam() } }
                .disabled(!isSeamToolActive || seamEditor.isBusy)
            Button("Undo") { seamEditor.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(seamEditor.seams.isEmpty)
            Button("Clear") { seamEditor.clearAll() }
                .disabled(seamEditor.seams.isEmpty)
            Button("Reset View") { cameraResetToken += 1 }
                .disabled(seamEditor.mesh == nil)
            Divider().frame(height: 16)
            Picker("Fabric", selection: $fabricChoice) {
                ForEach(FabricChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 190)
            Button(isFlattening ? "Flattening…" : "Flatten") { flattenSelectedPiece() }
                .disabled(seamEditor.mesh == nil || isFlattening || seamEditor.isBusy)
            Spacer()
            Text(seamEditor.message ?? "\(seamEditor.seams.count) seam(s). Click to add, Shift-click for a new seam.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func persistSeams(_ seams: [SeamPath]) {
        guard let piece = selectedPiece, seamEditor.loadedPieceID == piece.id else { return }
        do {
            let data = seams.isEmpty ? Data() : try JSONEncoder().encode(seams.map(\.vertices))
            guard data != piece.seamPathData else { return }
            piece.seamPathData = data
            piece.pattern?.modifiedAt = .now
            try modelContext.save()
        } catch {
            present(error)
        }
    }

    private func createPattern() {
        let pattern = Pattern(name: "Untitled Pattern")
        modelContext.insert(pattern)
        do {
            try modelContext.save()
            selectedPatternID = pattern.id
        } catch {
            present(error)
        }
    }

    @discardableResult
    private func addPiece(to pattern: Pattern) -> PatternPiece {
        let nextOrder = (pattern.pieces.map(\.sortOrder).max() ?? -1) + 1
        let piece = PatternPiece(name: "Piece \(nextOrder + 1)", sortOrder: nextOrder, pattern: pattern)
        pattern.modifiedAt = .now
        modelContext.insert(piece)
        do {
            try modelContext.save()
            selectedPieceID = piece.id
        } catch {
            present(error)
        }
        return piece
    }

    private func delete(_ pattern: Pattern) {
        if selectedPatternID == pattern.id {
            selectedPatternID = nil
            selectedPieceID = nil
        }
        modelContext.delete(pattern)
        do {
            try modelContext.save()
        } catch {
            present(error)
        }
    }

    private static let modelTypes: [UTType] = [
        UTType(filenameExtension: "obj"),
        UTType(filenameExtension: "stl", conformingTo: .data),
        .usdz,
    ].compactMap { $0 }

    private func beginImport(_ kind: ImportKind) {
        guard selectedPattern != nil else { return }
        if kind == .image, apiKey.isEmpty {
            present(MeshyError.missingAPIKey)
            return
        }
        fileImportKind = kind
        importProgressLabel = kind == .localImage
            ? "Running on the Neural Engine..."
            : "Importing and validating mesh..."
        isChoosingFile = true
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first, let pattern = selectedPattern else { return }
            switch fileImportKind {
            case .image:
                ingest(with: APIMeshProvider(apiKey: apiKey, imageURL: url), into: pattern)
            case .localImage:
                ingest(with: CoreMLMeshProvider(imageURL: url), into: pattern)
            case .model:
                ingest(with: LocalMeshProvider(fileURL: url), into: pattern)
            }
        case .failure(let error):
            present(error)
        }
    }

    /// Awaits a provider, injects the node into the canvas by recording it for the piece, and stores the
    /// validated arrays. Nothing is stored or shown unless the provider returned successfully.
    private func ingest(with provider: some MeshIngestionService, into pattern: Pattern) {
        let target = selectedPiece
        importStatus = nil
        isImporting = true
        Task {
            do {
                let (node, mesh) = try await provider.ingest()
                let piece = target ?? addPiece(to: pattern)
                try persist(mesh, into: piece, format: provider.sourceFormat, name: provider.suggestedName)
                selectedPieceID = piece.id
                ingestedNode = (piece.id, node)
                ingestedMesh = (piece.id, mesh)
                flattening = nil
                meshReloadToken += 1
                importStatus = "\(mesh.vertices.count) vertices, \(mesh.triangles.count) faces validated and ready for flattening."
                isImporting = false
            } catch is CancellationError {
                isImporting = false
            } catch {
                isImporting = false
                present(error)
            }
        }
    }

    /// Runs the topology engine off the main actor on the ingested vertex/face arrays (or, for a piece
    /// loaded from storage, the identical arrays rebuilt from SwiftData) bounded by the current seams.
    private func flattenSelectedPiece() {
        guard let topology = seamEditor.mesh, let piece = selectedPiece else { return }
        let input: (positions: [Vec3], triangles: [Int32])
        if let ingestedMesh, ingestedMesh.pieceID == piece.id {
            input = ingestedMesh.mesh.topologyInput
        } else {
            input = (topology.positions, topology.triangles)
        }
        let seams = seamEditor.seams.map(\.vertices)
        let fabric = fabricChoice.profile
        isFlattening = true
        importStatus = nil
        Task {
            do {
                let result = try await offMainActor {
                    try TopologyEngine.flatten(positions: input.positions, triangles: input.triangles, seams: seams, fabric: fabric)
                }
                flattening = result
                let worst = result.islands.map(\.report.areaDelta).max() ?? 0
                let darts = result.islands.reduce(0) { $0 + $1.darts.count }
                importStatus = "Flattened \(result.islands.count) island(s); worst area delta \((worst * 100).formatted(.number.precision(.fractionLength(2))))%, \(darts) dart(s)."
            } catch {
                present(error)
            }
            isFlattening = false
        }
    }

    private func persist(_ mesh: ImportedMesh, into piece: PatternPiece, format: String, name: String) throws {
        let faceData = try mesh.faceIndexData()
        var coordinates = [Double]()
        coordinates.reserveCapacity(mesh.vertices.count * 3)
        for vertex in mesh.vertices {
            coordinates.append(contentsOf: [vertex.x, vertex.y, vertex.z])
        }

        for oldPoint in piece.controlPoints {
            modelContext.delete(oldPoint)
        }
        piece.controlPoints = []
        piece.vertexData = coordinates.withUnsafeBytes { Data($0) }
        piece.faceIndexData = faceData
        piece.seamPathData = Data()
        piece.sourceMeshFormat = format
        piece.name = name
        piece.pattern?.modifiedAt = .now
        try modelContext.save()
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }
}

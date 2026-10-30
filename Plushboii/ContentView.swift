import SwiftData
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Pattern.createdAt, order: .reverse) private var patterns: [Pattern]

    @State private var selectedPatternID: UUID?
    @State private var selectedPieceID: UUID?
    @State private var apiKey = ""
    @State private var isImporting = false
    @State private var isChoosingImage = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var importStatus: String?
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
        return "\(piece.id)-\(piece.controlPoints.count)-\(piece.faceIndexData.count)-\(meshReloadToken)"
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
            isPresented: $isChoosingImage,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: handleImageSelection
        )
        .alert("Mesh Import Failed", isPresented: $showError) {
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
                    Button {
                        isChoosingImage = true
                    } label: {
                        Label(isImporting ? "Generating…" : "Generate 3D", systemImage: "cube.transparent")
                    }
                    .disabled(isImporting || apiKey.isEmpty || selectedPiece == nil)
                }
                .padding()

                if let selectedPiece {
                    seamToolbar
                    MeshSceneView(
                        mesh: seamEditor.mesh,
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
                                    seamEditor.message ?? "Generate a mesh from an image to preview it here."
                                )
                            )
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Pattern Pieces",
                        systemImage: "square.dashed",
                        description: Text("Add a piece, then generate a 3D mesh from an image.")
                    )
                }

                HStack {
                    SecureField("Meshy API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                    if isImporting {
                        ProgressView()
                            .controlSize(.small)
                        Text("Generating and validating mesh...")
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

    private func addPiece(to pattern: Pattern) {
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

    private func handleImageSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first, let selectedPiece else { return }
            importImage(at: url, into: selectedPiece)
        case .failure(let error):
            present(error)
        }
    }

    private func importImage(at url: URL, into piece: PatternPiece) {
        guard !apiKey.isEmpty else {
            present(MeshyError.missingAPIKey)
            return
        }
        importStatus = nil
        isImporting = true
        Task {
            do {
                let imageData = try await Task.detached(priority: .userInitiated) {
                    let hasAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if hasAccess { url.stopAccessingSecurityScopedResource() }
                    }
                    return try Data(contentsOf: url)
                }.value
                let mimeType = Self.mimeType(for: url)
                let result = try await MeshyClient(apiKey: apiKey).generate(from: imageData, mimeType: mimeType)
                try persist(result.mesh, into: piece)
                meshReloadToken += 1
                importStatus = "OBJ and USDZ saved to \(result.objFileURL.deletingLastPathComponent().path)"
                isImporting = false
            } catch {
                isImporting = false
                present(error)
            }
        }
    }

    private func persist(_ mesh: ImportedMesh, into piece: PatternPiece) throws {
        let faceData = try JSONEncoder().encode(mesh.triangles.map { [$0.a, $0.b, $0.c] })
        let points = mesh.vertices.enumerated().map { index, vertex in
            ControlPoint(index: index, x: vertex.x, y: vertex.y, z: vertex.z)
        }

        for oldPoint in piece.controlPoints {
            modelContext.delete(oldPoint)
        }
        piece.controlPoints = points
        piece.faceIndexData = faceData
        piece.seamPathData = Data()
        piece.sourceMeshFormat = "obj"
        piece.name = "Generated Mesh"
        piece.pattern?.modifiedAt = .now
        for point in points {
            modelContext.insert(point)
        }
        try modelContext.save()
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }

    private static func mimeType(for url: URL) -> String {
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

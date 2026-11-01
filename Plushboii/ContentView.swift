import AppKit
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

private enum PatternPDFKind {
    case tiled
    case a0

    var fileName: String {
        switch self {
        case .tiled: "Plushboii-Pattern-US-Letter"
        case .a0: "Plushboii-Pattern-A0"
        }
    }
}

private struct PatternPDFDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
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
    @State private var showHeatmap = false
    @State private var heatSeverity: [Double]?
    @State private var heatToken = 0
    @State private var qualitySummary: String?
    @State private var dedupeCongruent = true
    @State private var labelSeams = true
    @State private var showFurArrows = true
    @State private var fabricWidthCm = "110"
    @State private var fabricNeeded: String?
    @State private var flattening: FlatteningResult?
    @State private var centimetersPerMeshUnit = ""
    @State private var plushHeightCentimeters = ""
    @State private var patternDocument = PatternPDFDocument(data: Data())
    @State private var isSavingPattern = false
    @State private var patternFileName = PatternPDFKind.tiled.fileName
    @State private var autoPatternPieceID: UUID?
    @State private var seamSuggestions: [SeamSuggestion] = []
    @State private var seamAdviceStatus: String?
    @State private var plushiePatternPlan: PlushiePatternPlan?
    @State private var pendingMeshSplit: [MeshComponent]?
    @State private var pendingAnatomicalSplit: (components: [MeshComponent], plan: AnatomicalCutPlan)?
    @State private var isAnalyzingAnatomy = false
    @State private var anatomyPreviewToken = 0
    @State private var isSuggestingSeams = false
    @State private var ollamaModels: [String] = []
    @State private var ollamaModel = ""
    @State private var ollamaStatus: String?
    @State private var isLoadingOllamaModels = false
    @State private var referenceImageForPiece: (pieceID: UUID, url: URL)?
    @State private var previewSeamSuggestionID: String?
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var importStatus: String?
    @State private var importProgressLabel = "Importing and validating mesh..."
    @State private var seamEditor = SeamEditorState()
    @State private var isSeamToolActive = false
    @State private var joints: [AnatomicalJoint] = []
    @State private var isPlacingJoint = false
    @State private var jointAxis: AnatomicalAxis = .y
    @State private var cameraResetToken = 0
    @State private var meshReloadToken = 0

    private var selectedPattern: Pattern? {
        patterns.first { $0.id == selectedPatternID }
    }

    private var selectedPiece: PatternPiece? {
        selectedPattern?.pieces.first { $0.id == selectedPieceID }
    }

    private var patternDomainSelection: Binding<PatternDomain> {
        Binding(
            get: {
                selectedPattern.flatMap { PatternDomain(rawValue: $0.domainRawValue) } ?? .plushie
            },
            set: { selectedPattern?.domainRawValue = $0.rawValue }
        )
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
        .fileExporter(
            isPresented: $isSavingPattern,
            document: patternDocument,
            contentType: .pdf,
            defaultFilename: patternFileName
        ) { result in
            if case .failure(let error) = result {
                present(error)
            }
        }
        .alert("Operation Failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .confirmationDialog(
            "Create Separate Mesh Pieces?",
            isPresented: Binding(
                get: { pendingMeshSplit != nil || pendingAnatomicalSplit != nil },
                set: {
                    if !$0 {
                        pendingMeshSplit = nil
                        pendingAnatomicalSplit = nil
                        anatomyPreviewToken += 1
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let pendingAnatomicalSplit {
                Button("Create \(pendingAnatomicalSplit.components.count) Anatomy Pieces") {
                    createPieces(from: pendingAnatomicalSplit.components, anatomyPlan: pendingAnatomicalSplit.plan)
                }
            } else if let pendingMeshSplit {
                Button("Create \(pendingMeshSplit.count) Pieces") {
                    createPieces(from: pendingMeshSplit)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingMeshSplit = nil
                pendingAnatomicalSplit = nil
                anatomyPreviewToken += 1
            }
        } message: {
            if let pendingAnatomicalSplit {
                let boundaries = pendingAnatomicalSplit.plan.cuts.isEmpty
                    ? ""
                    : "Proposed boundaries: " + pendingAnatomicalSplit.plan.cuts.map(\.boundary).joined(separator: ", ") + ". "
                Text(
                    "\(pendingAnatomicalSplit.components.count) color-separated mesh regions are previewed in the canvas. "
                    + "\(boundaries)\(pendingAnatomicalSplit.plan.summary) "
                    + "Review the cut locations before creating pieces; nothing is saved until you confirm."
                )
            } else if let pendingMeshSplit {
                Text(
                    "\(pendingMeshSplit.count) independent mesh pieces will be created from the current seam paths. "
                    + "The original mesh will remain unchanged; flatten each new piece separately."
                )
            }
        }
        .onChange(of: selectedPatternID) { _, _ in
            pendingMeshSplit = nil
            pendingAnatomicalSplit = nil
            joints = []
            isPlacingJoint = false
            anatomyPreviewToken += 1
            selectedPieceID = selectedPattern?.pieces.sorted(by: { $0.sortOrder < $1.sortOrder }).first?.id
        }
        .onChange(of: selectedPieceID) { _, _ in
            pendingMeshSplit = nil
            pendingAnatomicalSplit = nil
            joints = []
            isPlacingJoint = false
            anatomyPreviewToken += 1
        }
        .onChange(of: selectedPattern?.domainRawValue) { _, _ in
            seamSuggestions = []
        plushiePatternPlan = nil
        previewSeamSuggestionID = nil
        seamAdviceStatus = nil
        }
        .task(id: meshToken) {
            await seamEditor.load(piece: selectedPiece)
            seamSuggestions = []
            plushiePatternPlan = nil
            previewSeamSuggestionID = nil
            guard let piece = selectedPiece, autoPatternPieceID == piece.id else { return }
            autoPatternPieceID = nil
            guard let topology = seamEditor.mesh else {
                importStatus = seamEditor.message ?? "The imported mesh could not be prepared for pattern making."
                return
            }
            await makePattern(
                positions: topology.positions,
                triangles: topology.triangles,
                seams: [],
                automatic: true
            )
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
                    Picker("Pattern type", selection: patternDomainSelection) {
                        ForEach(PatternDomain.allCases) { domain in
                            Text(domain.displayName).tag(domain)
                        }
                    }
                    .frame(maxWidth: 180)
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
                    jointToolbar
                    if !seamSuggestions.isEmpty || seamAdviceStatus != nil {
                        seamSuggestionList
                    }
                    if flattening != nil {
                        patternOutputToolbar
                    }
                    MeshSceneView(
                        mesh: seamEditor.mesh,
                        ingestedNode: ingestedNode?.pieceID == selectedPiece.id ? ingestedNode?.node : nil,
                        seams: seamEditor.seams,
                        suggestedSeams: seamSuggestions.filter { $0.id == previewSeamSuggestionID },
                        previewComponents: pendingAnatomicalSplit?.components,
                        previewToken: anatomyPreviewToken,
                        heatSeverity: showHeatmap ? heatSeverity : nil,
                        heatToken: heatToken,
                        joints: joints,
                        isPickingEnabled: (isSeamToolActive || isPlacingJoint) && seamEditor.mesh != nil,
                        resetToken: cameraResetToken,
                        onPick: { vertex, startNew in
                            if isPlacingJoint {
                                placeJoint(atVertex: vertex)
                            } else {
                                Task { await seamEditor.pick(vertex: vertex, startingNewSeam: startNew) }
                            }
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

                HStack(spacing: 8) {
                    SecureField("Meshy API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                    Picker("Local model", selection: $ollamaModel) {
                        Text("Select Ollama model").tag("")
                        ForEach(ollamaModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .frame(maxWidth: 230)
                    .help("For image-based pattern advice, select a vision-capable model already installed in Ollama.")
                    Button(isLoadingOllamaModels ? "Checking…" : "Find Models") {
                        Task { await refreshOllamaModels() }
                    }
                    .disabled(isLoadingOllamaModels)
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
                    if let ollamaStatus {
                        Text(ollamaStatus)
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

    private var jointToolbar: some View {
        let busy = seamEditor.mesh == nil || isFlattening || isAnalyzingAnatomy || seamEditor.isBusy
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Label("Joints", systemImage: "figure.arms.open")
                    .font(.subheadline.weight(.medium))
                Button("Propose Joints") { proposeJoints() }
                    .disabled(busy)
                    .help("Find narrow cross-sections between bulky regions, such as a neck or limb root.")
                Toggle(isOn: $isPlacingJoint) {
                    Label("Place Joint", systemImage: "mappin.and.ellipse")
                }
                .toggleStyle(.button)
                .disabled(busy)
                .help("Click the mesh where a part is sewn on. The cut is a plane through the click, perpendicular to the chosen axis.")
                Picker("Axis", selection: $jointAxis) {
                    ForEach(AnatomicalAxis.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 100)
                Button("Split at Joints") { splitAtJoints() }
                    .disabled(busy || joints.isEmpty || !seamEditor.seams.isEmpty)
                Button("Clear Joints") { joints = []; isPlacingJoint = false }
                    .disabled(joints.isEmpty)
                Spacer()
            }
            ForEach($joints) { $joint in
                HStack(spacing: 8) {
                    TextField("Joint name", text: $joint.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    Text(jointAxisName(joint.direction))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        joints.removeAll { $0.id == joint.id }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Remove this joint")
                    Spacer()
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private func jointAxisName(_ direction: Vec3) -> String {
        let components = [("X", direction.x), ("Y", direction.y), ("Z", direction.z)]
        guard let dominant = components.max(by: { abs($0.1) < abs($1.1) }) else { return "" }
        return abs(dominant.1) > 0.999 ? "\(dominant.0) axis" : "tilted"
    }

    private func placeJoint(atVertex vertex: Int) {
        guard let topology = seamEditor.mesh, topology.positions.indices.contains(vertex) else { return }
        let direction: Vec3 = switch jointAxis {
        case .x: Vec3(1, 0, 0)
        case .y: Vec3(0, 1, 0)
        case .z: Vec3(0, 0, 1)
        }
        joints.append(AnatomicalJoint(
            name: "Joint \(joints.count + 1)",
            position: topology.positions[vertex],
            direction: direction,
            positiveLabel: "",
            negativeLabel: ""
        ))
        importStatus = "Joint placed. Joints are applied in order, so place the neck or the root of the largest part first."
    }

    private func proposeJoints() {
        guard let topology = seamEditor.mesh else { return }
        let positions = topology.positions
        let triangles = topology.triangles
        let meshID = topology.id
        Task {
            guard let proposed = try? await offMainActor({ JointProposer.propose(positions: MeshSmoothing.taubin(positions: positions, triangles: triangles), triangles: triangles) }) else { return }
            guard seamEditor.mesh?.id == meshID else { return }
            joints = proposed
            importStatus = proposed.isEmpty
                ? "No clear joints were found. Use Place Joint to mark where parts are sewn together."
                : "Proposed \(proposed.count) joint(s). Rename, delete or add joints, then choose Split at Joints."
        }
    }

    private func splitAtJoints() {
        guard let topology = seamEditor.mesh, !joints.isEmpty else { return }
        let positions = topology.positions
        let triangles = topology.triangles
        let snapshot = joints
        let meshID = topology.id
        isPlacingJoint = false
        Task {
            do {
                let components = try await offMainActor {
                    try StagedAnatomySplit.split(positions: MeshSmoothing.taubin(positions: positions, triangles: triangles), triangles: triangles, joints: snapshot)
                }
                guard seamEditor.mesh?.id == meshID else { return }
                let summary = "Joints: " + snapshot.map(\.name).joined(separator: ", ") + "."
                pendingMeshSplit = nil
                pendingAnatomicalSplit = (components, AnatomicalCutPlan(summary: summary, cuts: []))
                anatomyPreviewToken += 1
                importStatus = "Review the color-coded split at your joints before confirming."
            } catch {
                present(error)
            }
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
            Button(isSuggestingSeams ? "Suggesting…" : "Suggest Cuts") {
                Task { await suggestSeams() }
            }
            .disabled(seamEditor.mesh == nil || isSuggestingSeams || isFlattening || seamEditor.isBusy)
            Button(isAnalyzingAnatomy ? "Analyzing…" : "Analyze Anatomy") {
                Task { await analyzeAnatomy() }
            }
            .disabled(
                seamEditor.mesh == nil || isAnalyzingAnatomy || isSuggestingSeams
                    || isFlattening || isImporting || seamEditor.isBusy || !seamEditor.seams.isEmpty
                    || ollamaModel.isEmpty
                    || (selectedPattern.flatMap { PatternDomain(rawValue: $0.domainRawValue) } ?? .plushie) != .plushie
            )
            .help("Use registered front, side, and top mesh views with a vision-capable local Ollama model.")
            Button("Split Mesh") {
                splitSelectedMesh()
            }
            .disabled(seamEditor.mesh == nil || isSuggestingSeams || isAnalyzingAnatomy || isFlattening || seamEditor.isBusy)
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

    private var seamSuggestionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let seamAdviceStatus {
                Text(seamAdviceStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let plushiePatternPlan {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Local plushie design interpretation")
                        .font(.caption.weight(.semibold))
                    Text(plushiePatternPlan.visualSummary)
                        .font(.caption)
                    Text("Construction: \(plushiePatternPlan.bodyConstruction)")
                        .font(.caption)
                    if !plushiePatternPlan.visibleComponents.isEmpty {
                        Text("Visible components: \(plushiePatternPlan.visibleComponents.joined(separator: ", "))")
                            .font(.caption)
                    }
                    Text("Head, torso, and appendage guidance only; eyes, nose, and mouth are post-production details. Panel boundaries still come from the verified mesh layout.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }
            ForEach(seamSuggestions) { suggestion in
                HStack(spacing: 8) {
                    Text(suggestion.title)
                        .font(.subheadline.weight(.medium))
                    Text("Area Δ \(String(format: "%.2f", suggestion.worstAreaDelta * 100))% · stitch mismatch \(String(format: "%.1f", suggestion.worstStitchLengthMismatch * 100))% · largest panel \(String(format: "%.0f", suggestion.largestPanelAreaShare * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(suggestion.rationale)
                    Spacer(minLength: 4)
                    Button(previewSeamSuggestionID == suggestion.id ? "Previewing" : "Preview") {
                        previewSeamSuggestionID = suggestion.id
                    }
                    Button("Apply") {
                        seamEditor.applySuggestion(suggestion.seamPaths)
                        previewSeamSuggestionID = nil
                        seamSuggestions.removeAll { $0.id == suggestion.id }
                        flattening = nil; heatSeverity = nil; heatToken += 1
                        importStatus = "Verified panel layout applied. Edit its stitch lines if needed, then choose Flatten."
                    }
                }
            }
            HStack {
                Text("Purple lines are a proposed layout; orange lines are applied cuts. Area and paired stitch lengths inform ranking.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Dismiss") {
                    seamSuggestions = []
                    plushiePatternPlan = nil
                    previewSeamSuggestionID = nil
                    seamAdviceStatus = nil
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var patternOutputToolbar: some View {
        HStack(spacing: 10) {
            Label("\(flattening?.islands.count ?? 0) pattern panel(s) ready", systemImage: "checkmark.circle")
                .font(.caption)
            TextField("plush height (cm)", text: $plushHeightCentimeters)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
                .help("Finished height of the plush. Sets the scale from the model's height when cm per mesh unit is empty.")
            TextField("cm per mesh unit", text: $centimetersPerMeshUnit)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .help("Enter the known physical scale. OBJ and STL files may not specify real-world units.")
            Toggle("Stretch map", isOn: $showHeatmap)
                .toggleStyle(.button)
                .help(qualitySummary ?? "Show where fabric must stretch (red) on the 3D model")
            Menu("Options") {
                Toggle("Merge identical pieces", isOn: $dedupeCongruent)
                Toggle("Label seams", isOn: $labelSeams)
                Toggle("Fur direction arrows", isOn: $showFurArrows)
            }
            TextField("fabric cm", text: $fabricWidthCm)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .help("Fabric width in centimeters")
            Button("Fabric Needed") { calculateFabric() }
            Button("Export SVG") { saveSVG() }
            Menu("Save Pattern PDF") {
                Button("US Letter tiled PDF") {
                    savePatternPDF(.tiled)
                }
                Button("A0 PDF") {
                    savePatternPDF(.a0)
                }
            }
            .disabled(isFlattening || isSavingPattern || centimetersPerMeshUnitValue == nil)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var centimetersPerMeshUnitValue: Double? {
        if let value = Double(centimetersPerMeshUnit.trimmingCharacters(in: .whitespacesAndNewlines)),
           value.isFinite, value > 0 {
            return value
        }
        guard let height = Double(plushHeightCentimeters.trimmingCharacters(in: .whitespacesAndNewlines)),
              height.isFinite, height > 0,
              let positions = seamEditor.mesh?.positions,
              let up = ModelPreparation.orientationCandidates(positions: positions).first?.up else { return nil }
        let heights = positions.map { vdot($0, up) }
        guard let low = heights.min(), let high = heights.max(), high - low > 0 else { return nil }
        return height / (high - low)
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
                ingest(with: APIMeshProvider(apiKey: apiKey, imageURL: url), into: pattern, referenceImageURL: url)
            case .localImage:
                ingest(with: CoreMLMeshProvider(imageURL: url), into: pattern, referenceImageURL: url)
            case .model:
                ingest(with: LocalMeshProvider(fileURL: url), into: pattern)
            }
        case .failure(let error):
            present(error)
        }
    }

    /// Awaits a provider, injects the node into the canvas by recording it for the piece, and stores the
    /// validated arrays. Nothing is stored or shown unless the provider returned successfully.
    private func ingest(
        with provider: some MeshIngestionService,
        into pattern: Pattern,
        referenceImageURL: URL? = nil
    ) {
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
                referenceImageForPiece = referenceImageURL.map { (piece.id, $0) }
                flattening = nil; heatSeverity = nil; heatToken += 1
                seamSuggestions = []
                plushiePatternPlan = nil
                seamAdviceStatus = nil
                previewSeamSuggestionID = nil
                centimetersPerMeshUnit = ""
                plushHeightCentimeters = ""
                meshReloadToken += 1
                autoPatternPieceID = piece.id
                importStatus = "\(mesh.vertices.count) vertices, \(mesh.triangles.count) faces validated. Creating a pattern…"
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
        Task {
            await makePattern(
                positions: input.positions,
                triangles: input.triangles,
                seams: seams,
                automatic: false
            )
        }
    }

    private func suggestSeams() async {
        guard let topology = seamEditor.mesh, let selectedPattern else { return }
        let domain = PatternDomain(rawValue: selectedPattern.domainRawValue) ?? .plushie
        isSuggestingSeams = true
        seamSuggestions = []
        plushiePatternPlan = nil
        previewSeamSuggestionID = nil
        defer { isSuggestingSeams = false }

        let fabric = fabricChoice.profile
        do {
            let candidates = try await offMainActor {
                try SeamSuggestionEngine.suggest(
                    positions: topology.positions,
                    triangles: topology.triangles,
                    fabric: fabric
                )
            }
            guard !candidates.isEmpty else {
                seamAdviceStatus = "No verified layout was found among the principal-axis cut networks for this fabric. Add or adjust seams manually, then flatten to check them."
                return
            }

            let referenceImageURL = referenceImageForPiece.flatMap {
                $0.pieceID == selectedPiece?.id ? $0.url : nil
            }
            let advice = await OnDeviceSeamAdvisor.rank(
                candidates,
                domain: domain,
                vertexCount: topology.positions.count,
                faceCount: topology.triangles.count / 3,
                model: ollamaModel,
                referenceImageURL: referenceImageURL
            )

            switch advice {
            case .ranked(let candidateIDs, let plan):
                let rank = Dictionary(uniqueKeysWithValues: candidateIDs.enumerated().map { ($1, $0) })
                seamSuggestions = candidates.sorted {
                    (rank[$0.id] ?? Int.max) < (rank[$1.id] ?? Int.max)
                }
                plushiePatternPlan = plan
                seamAdviceStatus = plan == nil
                    ? "Ollama ranked layouts that already passed flattening verification. Review each before applying."
                    : "Ollama interpreted the reference image and ranked only verified mesh-derived layouts. Review all suggestions before applying."
            case .unavailable(let reason):
                seamSuggestions = candidates
                seamAdviceStatus = "Local model unavailable: \(reason) Showing layouts ranked by verified distortion, panel balance, and cut length."
            case .failed(let reason):
                seamSuggestions = candidates
                seamAdviceStatus = "Local model request failed: \(reason) Showing layouts ranked by verified distortion, panel balance, and cut length."
            }
        } catch {
            present(error)
        }
    }

    private func splitSelectedMesh() {
        guard let topology = seamEditor.mesh else { return }
        let positions = topology.positions.map { Vec3($0.x, $0.y, $0.z) }
        let triangles = topology.triangles
        let seams = seamEditor.seams.map(\.vertices)
        let pieceID = selectedPieceID
        Task {
            do {
                let components = try await offMainActor {
                    try MeshComponentSplitter.split(
                        positions: positions,
                        triangles: triangles,
                        seams: seams
                    )
                }
                guard selectedPieceID == pieceID, seamEditor.mesh?.id == topology.id else { return }
                pendingMeshSplit = components
                pendingAnatomicalSplit = nil
            } catch {
                present(error)
            }
        }
    }

    private func analyzeAnatomy() async {
        guard let topology = seamEditor.mesh else { return }
        guard !ollamaModel.isEmpty else {
            importStatus = "Choose a vision-capable local Ollama model before analyzing anatomy."
            return
        }
        guard seamEditor.seams.isEmpty else {
            importStatus = "Clear manual seams before generating anatomy-based mesh pieces."
            return
        }
        let domain = selectedPattern.flatMap { PatternDomain(rawValue: $0.domainRawValue) } ?? .plushie
        guard domain == .plushie else {
            importStatus = "Anatomical mesh splitting is available for plushie patterns."
            return
        }

        isAnalyzingAnatomy = true
        importStatus = "Rendering registered front, side, and top views…"
        defer { isAnalyzingAnatomy = false }
        let pieceID = selectedPieceID
        do {
            let positions = topology.positions
            let triangles = topology.triangles
            let views = try await offMainActor {
                try AnatomyMeshViewRenderer.render(positions: positions, triangles: triangles)
            }
            guard selectedPieceID == pieceID, seamEditor.mesh?.id == topology.id, seamEditor.seams.isEmpty else { return }
            importStatus = "Asking the local vision model for anatomical boundaries…"
            let plan = try await OnDeviceSeamAdvisor.suggestAnatomy(views: views, model: ollamaModel)
            guard selectedPieceID == pieceID, seamEditor.mesh?.id == topology.id, seamEditor.seams.isEmpty else { return }
            let components = try await offMainActor {
                try StagedAnatomySplit.split(positions: positions, triangles: triangles, cuts: plan.cuts)
            }
            guard selectedPieceID == pieceID, seamEditor.mesh?.id == topology.id, seamEditor.seams.isEmpty else { return }
            pendingMeshSplit = nil
            pendingAnatomicalSplit = (components, plan)
            anatomyPreviewToken += 1
            importStatus = "Review the color-coded anatomy split in the canvas before confirming."
        } catch {
            importStatus = "Anatomical analysis failed: \(error.localizedDescription)"
        }
    }

    private func createPieces(from components: [MeshComponent], anatomyPlan: AnatomicalCutPlan? = nil) {
        guard let pattern = selectedPattern, let sourcePiece = selectedPiece else { return }
        pendingMeshSplit = nil
        pendingAnatomicalSplit = nil
        anatomyPreviewToken += 1
        let format = sourcePiece.sourceMeshFormat ?? "mesh"
        var nextOrder = (pattern.pieces.map(\.sortOrder).max() ?? -1) + 1
        var createdPieces: [PatternPiece] = []

        do {
            for (index, component) in components.enumerated() {
                let mesh = ImportedMesh(
                    vertices: component.positions.map { MeshVertex(x: $0.x, y: $0.y, z: $0.z) },
                    triangles: stride(from: 0, to: component.triangles.count, by: 3).map { corner in
                        MeshTriangle(
                            a: Int(component.triangles[corner]),
                            b: Int(component.triangles[corner + 1]),
                            c: Int(component.triangles[corner + 2])
                        )
                    }
                )
                let piece = PatternPiece(
                    name: anatomyPlan == nil
                        ? "\(sourcePiece.name) - segment \(index + 1)"
                        : "\(sourcePiece.name) - \(component.anatomicalLabel ?? "anatomy") \(index + 1)",
                    sortOrder: nextOrder,
                    sourceMeshFormat: format,
                    pattern: pattern
                )
                nextOrder += 1
                modelContext.insert(piece)
                createdPieces.append(piece)
                try persist(mesh, into: piece, format: format, name: piece.name, saveChanges: false)
            }
            try modelContext.save()
            pattern.modifiedAt = .now
            selectedPieceID = createdPieces.first?.id
            ingestedNode = nil
            ingestedMesh = nil
            flattening = nil; heatSeverity = nil; heatToken += 1
            seamSuggestions = []
            plushiePatternPlan = nil
            previewSeamSuggestionID = nil
            seamAdviceStatus = nil
            meshReloadToken += 1
            if let anatomyPlan {
                let boundaries = anatomyPlan.cuts.isEmpty ? anatomyPlan.summary : "Boundaries: " + anatomyPlan.cuts.map(\.boundary).joined(separator: ", ") + "."
                importStatus = "Created \(createdPieces.count) anatomy pieces. \(boundaries) Review each piece and flatten it independently."
            } else {
                importStatus = "Created \(createdPieces.count) separate mesh pieces. Review each piece and flatten it independently."
            }
        } catch {
            for piece in createdPieces {
                modelContext.delete(piece)
            }
            present(error)
        }
    }

    private func refreshOllamaModels() async {
        isLoadingOllamaModels = true
        defer { isLoadingOllamaModels = false }
        do {
            ollamaModels = try await OnDeviceSeamAdvisor.availableModels()
            if !ollamaModels.contains(ollamaModel) {
                ollamaModel = ollamaModels.first ?? ""
            }
            ollamaStatus = ollamaModels.isEmpty
                ? "Ollama is running, but no local models are installed."
                : "Local Ollama models found. Choose a vision-capable model for image-based guidance."
        } catch {
            ollamaModels = []
            ollamaModel = ""
            ollamaStatus = error.localizedDescription
        }
    }

    private func makePattern(
        positions: [Vec3],
        triangles: [Int32],
        seams: [[Int]],
        automatic: Bool
    ) async {
        let fabric = fabricChoice.profile
        isFlattening = true
        importStatus = automatic ? "Making a pattern from the imported mesh…" : nil
        defer { isFlattening = false }
        do {
            let result = try await offMainActor {
                try TopologyEngine.flatten(
                    positions: positions,
                    triangles: triangles,
                    seams: seams,
                    fabric: fabric
                )
            }
            flattening = result
            let quality = try await offMainActor {
                let q = result.islands.map { PatternQualityMap.evaluate(island: $0, positions: positions) }
                return (
                    PatternQualityMap.meshVertexSeverity(result: result, positions: positions),
                    q.map(\.worstStretch).max() ?? 0,
                    q.reduce(0) { $0 + $1.flippedTriangles }
                )
            }
            heatSeverity = quality.0.count == seamEditor.mesh?.positions.count ? quality.0 : nil
            heatToken += 1
            qualitySummary = "Worst stretch \((quality.1 * 100).formatted(.number.precision(.fractionLength(0))))%"
                + (quality.2 > 0 ? ", \(quality.2) flipped triangle(s)" : "")
            let worst = result.islands.map(\.report.areaDelta).max() ?? 0
            let darts = result.islands.reduce(0) { $0 + $1.darts.count }
            importStatus = "Pattern ready: \(result.islands.count) panel(s), worst area delta \((worst * 100).formatted(.number.precision(.fractionLength(2))))%, \(darts) dart(s). Enter cm per mesh unit to export at physical scale."
        } catch {
            flattening = nil; heatSeverity = nil; heatToken += 1
            if automatic {
                importStatus = "Automatic pattern making needs a cuttable surface. \(error.localizedDescription) Add seams with Seam Tool, then choose Flatten."
            } else {
                present(error)
            }
        }
    }

    private var layoutOptions: LayoutOptions {
        var options = LayoutOptions()
        options.deduplicateCongruent = dedupeCongruent
        options.labelSeams = labelSeams
        options.furDirectionDegrees = showFurArrows ? 90 : nil
        if let piece = selectedPiece, let islands = flattening?.islands {
            for index in islands.indices {
                options.names[index] = "\(piece.name) - panel \(index + 1)"
            }
        }
        return options
    }

    private func calculateFabric() {
        guard let result = flattening, let scale = centimetersPerMeshUnitValue else { return }
        let width = Double(fabricWidthCm) ?? 0
        let options = layoutOptions
        Task {
            do {
                let plans = try await offMainActor {
                    let sheet = try PatternLayout.makeSheet(from: result, centimetersPerUnit: scale, options: options)
                    return try FabricCuttingPlanner.plan(sheet: sheet, widthsCm: ["Fabric": width])
                }
                fabricNeeded = plans.map {
                    String(format: "%@: %.0f cm × %.0f cm (%.0f%% used)", $0.fabric, $0.widthCm, $0.lengthCm, $0.utilization * 100)
                }.joined(separator: "\n")
                importStatus = "Fabric needed — " + (fabricNeeded ?? "")
            } catch {
                present(error)
            }
        }
    }

    private func saveSVG() {
        guard let result = flattening, let scale = centimetersPerMeshUnitValue else { return }
        let options = layoutOptions
        Task {
            do {
                let svg = try await offMainActor {
                    PatternSVGExporter.svg(try PatternLayout.makeSheet(from: result, centimetersPerUnit: scale, options: options))
                }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.svg]
                panel.nameFieldStringValue = "Plushboii-Pattern.svg"
                if panel.runModal() == .OK, let url = panel.url {
                    try svg.write(to: url, atomically: true, encoding: .utf8)
                }
            } catch {
                present(error)
            }
        }
    }

    private func savePatternPDF(_ kind: PatternPDFKind) {
        guard let result = flattening, let scale = centimetersPerMeshUnitValue else { return }
        let options = layoutOptions
        Task {
            do {
                let sheet = try await offMainActor {
                    try PatternLayout.makeSheet(from: result, centimetersPerUnit: scale, options: options)
                }
                let data: Data
                switch kind {
                case .tiled:
                    data = try await PatternPDFExporter.tiledPDF(sheet).data
                case .a0:
                    data = try await PatternPDFExporter.a0PDF(sheet)
                }
                patternDocument = PatternPDFDocument(data: data)
                patternFileName = kind.fileName
                isSavingPattern = true
            } catch {
                present(error)
            }
        }
    }

    private func persist(
        _ mesh: ImportedMesh,
        into piece: PatternPiece,
        format: String,
        name: String,
        saveChanges: Bool = true
    ) throws {
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
        if saveChanges { try modelContext.save() }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }
}

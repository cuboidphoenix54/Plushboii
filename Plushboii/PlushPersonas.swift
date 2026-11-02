import SwiftUI

struct PersonaMessage: Identifiable, Sendable, Equatable, Codable {
    enum Role: String, Sendable, Codable { case user, assistant }
    enum Rating: Int, Sendable, Codable { case down = -1, none = 0, up = 1 }

    var id = UUID()
    let role: Role
    let text: String
    var date = Date()
    var rating: Rating = .none
    /// Results computed by the app's geometry calculators for this answer, shown separately from the model's text.
    var verified: String?
}

struct PersonaMemory: Identifiable, Sendable, Equatable, Codable {
    enum Source: String, Sendable, Codable { case user, summary }

    var id = UUID()
    let text: String
    let source: Source
    /// Shared memories are visible to all three assistants; others only to `owner`.
    let shared: Bool
    let owner: String
    var date = Date()
}

/// A question and answer the user rated. Approved ones feed retrieval now and MLX training later.
struct PersonaExample: Identifiable, Sendable, Equatable, Codable {
    let id: UUID
    let persona: String
    let question: String
    let answer: String
    var verified: String?
}

struct PersonaSnapshot: Codable, Sendable {
    var transcripts: [String: [PersonaMessage]] = [:]
    var summarizedCount: [String: Int] = [:]
    var memories: [PersonaMemory] = []
    var approved: [PersonaExample] = []
    var rejected: [PersonaExample] = []
}

enum PersonaChatError: LocalizedError {
    case serverUnavailable
    case requestFailed(Int)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .serverUnavailable:
            "The MLX server is not reachable. Start PlushboiiTraining/run_server.sh, then try again."
        case .requestFailed(let status):
            "The MLX server returned HTTP \(status)."
        case .malformedResponse:
            "The MLX server sent a reply that could not be read."
        }
    }
}

/// Talks to the local MLX server. The persona prompt is folded into the first user turn because the server's
/// handling of a `system` role has not been verified for this model.
actor PersonaChatClient {
    struct Turn: Sendable {
        let role: String
        let text: String
    }

    private struct Part: Encodable, Sendable {
        let type: String
        let text: String
    }

    private struct Message: Encodable, Sendable {
        let role: String
        let content: [Part]
    }

    private struct Request: Encodable, Sendable {
        let model: String
        let adapterPath: String?
        let messages: [Message]
        let maxTokens: Int
        let temperature: Double
    }

    private struct Response: Decodable, Sendable {
        struct Choice: Decodable, Sendable {
            struct Msg: Decodable, Sendable { let content: String? }
            let message: Msg
        }
        let choices: [Choice]
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// `mlxvlm.personaAdapterPath` points chats at an adapter trained on approved persona answers. When unset, the
    /// request carries no adapter path.
    func complete(turns: [Turn], maxTokens: Int, temperature: Double) async throws -> String {
        let defaults = UserDefaults.standard
        let base = URL(string: defaults.string(forKey: "mlxvlm.baseURL") ?? "") ?? URL(string: "http://127.0.0.1:8080")!
        let adapter = defaults.string(forKey: "mlxvlm.personaAdapterPath")
        let body = Request(
            model: defaults.string(forKey: "mlxvlm.model") ?? "mlx-community/gemma-4-e4b-it-4bit",
            adapterPath: (adapter?.isEmpty ?? true) ? nil : adapter,
            messages: turns.map { Message(role: $0.role, content: [Part(type: "text", text: $0.text)]) },
            maxTokens: maxTokens,
            temperature: temperature
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var request = URLRequest(url: base.appending(path: "v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PersonaChatError.serverUnavailable
        }
        guard let http = response as? HTTPURLResponse else { throw PersonaChatError.malformedResponse }
        guard http.statusCode == 200 else { throw PersonaChatError.requestFailed(http.statusCode) }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let content = decoded.choices.first?.message.content
        else { throw PersonaChatError.malformedResponse }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Owns the files under Application Support/Plushboii/Personas. Writes are versioned so a late save never
/// overwrites a newer one.
actor PersonaDiskStore {
    static let directory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Plushboii/Personas", directoryHint: .isDirectory)

    private var lastVersion = 0

    private struct TrainingLine: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let images: [String] = []
        let messages: [Message]
    }

    func load() -> PersonaSnapshot {
        let url = Self.directory.appending(path: "state.json")
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(PersonaSnapshot.self, from: data)
        else { return PersonaSnapshot() }
        return snapshot
    }

    func save(_ snapshot: PersonaSnapshot, version: Int) throws {
        guard version > lastVersion else { return }
        lastVersion = version
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: Self.directory.appending(path: "state.json"), options: .atomic)
        try Self.jsonl(snapshot.approved).write(to: Self.directory.appending(path: "persona_training.jsonl"), options: .atomic)
        try Self.jsonl(snapshot.rejected).write(to: Self.directory.appending(path: "persona_rejected.jsonl"), options: .atomic)
    }

    /// Rows use the same `{"images":[],"messages":[...]}` shape as the other MLX datasets, with the prompt in
    /// the same persona-preamble form the app sends at inference time.
    private static func jsonl(_ examples: [PersonaExample]) throws -> Data {
        let encoder = JSONEncoder()
        var output = Data()
        for example in examples {
            guard let persona = PlushPersona(rawValue: example.persona) else { continue }
            let line = TrainingLine(messages: [
                .init(
                    role: "user",
                    content: persona.systemPrompt + "\n\nUser: " + example.question + PlushPersona.verifiedSuffix(example.verified)
                ),
                .init(role: "assistant", content: example.answer),
            ])
            output.append(try encoder.encode(line))
            output.append(0x0A)
        }
        return output
    }
}

enum PersonaRetrieval {
    private static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
    }

    /// Jaccard word overlap between the new question and previously approved questions for the same persona.
    static func topExamples(for question: String, in examples: [PersonaExample], persona: PlushPersona, limit: Int = 2) -> [PersonaExample] {
        let query = tokens(question)
        guard !query.isEmpty else { return [] }
        return examples
            .filter { $0.persona == persona.rawValue }
            .map { example -> (PersonaExample, Double) in
                let other = tokens(example.question)
                let union = query.union(other).count
                return (example, union == 0 ? 0 : Double(query.intersection(other).count) / Double(union))
            }
            .filter { $0.1 >= 0.2 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}

/// Single shared state so the picker window and the three standalone windows see the same conversations.
@MainActor
@Observable
final class PersonaHub {
    static let shared = PersonaHub()

    private(set) var snapshot = PersonaSnapshot()
    private(set) var thinking: Set<PlushPersona> = []
    private(set) var errors: [PlushPersona: String] = [:]

    private let client = PersonaChatClient()
    private let store = PersonaDiskStore()
    private var loaded = false
    private var version = 0
    private var compacting: Set<PlushPersona> = []

    private static let historyWindow = 12
    private static let compactAfter = 20
    private static let compactBatch = 10
    private static let maxStoredMessages = 400
    private static let maxPromptMemories = 20

    func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        snapshot = await store.load()
    }

    func messages(for persona: PlushPersona) -> [PersonaMessage] {
        snapshot.transcripts[persona.rawValue] ?? []
    }

    func memories(for persona: PlushPersona) -> [PersonaMemory] {
        snapshot.memories.filter { $0.shared || $0.owner == persona.rawValue }
    }

    var approvedCount: Int { snapshot.approved.count }

    /// Cheap gate so ordinary questions do not pay for an extra model call.
    private static let geometryKeywords = [
        "gore", "sphere", "orb", "cylinder", "circumference", "frustum", "cone", "slant", "dart",
        "gusset", "chibi", "proportion", "head height", "volume", "taper",
    ]

    /// The server sometimes drops the final closing brace, so up to two missing braces are restored before parsing.
    nonisolated static func jsonObject(from reply: String) -> [String: Any]? {
        guard let start = reply.firstIndex(of: "{") else { return nil }
        var text = String(reply[start...])
        if let end = text.lastIndex(of: "}") { text = String(text[...end]) }
        for extra in 0...2 {
            if let object = try? JSONSerialization.jsonObject(with: Data((text + String(repeating: "}", count: extra)).utf8)) as? [String: Any] {
                return object
            }
        }
        return nil
    }

    private func geometryResult(for question: String) async -> PatternGeometryTool.Result? {
        let lower = question.lowercased()
        guard lower.contains(where: \.isNumber), Self.geometryKeywords.contains(where: lower.contains) else { return nil }
        let catalog = PatternGeometryTool.allCases.map { "- \($0.rawValue): \($0.signature)" }.joined(separator: "\n")
        let prompt = """
        Pick the calculator that answers the question, or none. Reply with one JSON object only: \
        {"tool": "<name or none>", "args": {"<argument>": <number>}}. Use only numbers stated in the question, in the \
        user's own unit (convert diameter to radius or the reverse when the calculator needs it). Do not invent values. \
        If a required number is missing, reply {"tool": "none", "args": {}}.

        Calculators:
        \(catalog)

        Question: \(question)
        """
        guard let reply = try? await client.complete(turns: [.init(role: "user", text: prompt)], maxTokens: 120, temperature: 0),
              let object = Self.jsonObject(from: reply),
              let name = object["tool"] as? String, let tool = PatternGeometryTool(rawValue: name),
              let raw = object["args"] as? [String: Any]
        else { return nil }
        var args: [String: Double] = [:]
        for (key, value) in raw {
            if let number = value as? Double { args[key] = number }
        }
        return try? tool.run(args)
    }

    func send(_ text: String, as persona: PlushPersona) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !thinking.contains(persona) else { return }
        errors[persona] = nil

        if let fact = Self.rememberRequest(in: trimmed) {
            append(PersonaMessage(role: .user, text: trimmed), to: persona)
            addMemory(fact, source: .user, shared: true, owner: persona)
            append(PersonaMessage(role: .assistant, text: "Got it. I'll remember: \(fact)"), to: persona)
            persist()
            return
        }

        append(PersonaMessage(role: .user, text: trimmed), to: persona)
        thinking.insert(persona)
        persist()
        defer { thinking.remove(persona) }

        let verified = await geometryResult(for: trimmed)?.text
        let turns = promptTurns(for: persona, question: trimmed, verified: verified)
        do {
            let answer = try await client.complete(turns: turns, maxTokens: 400, temperature: 0.7)
            append(PersonaMessage(role: .assistant, text: answer, verified: verified), to: persona)
            persist()
            await compactIfNeeded(persona)
        } catch {
            errors[persona] = error.localizedDescription
        }
    }

    func rate(_ messageID: UUID, as persona: PlushPersona, to rating: PersonaMessage.Rating) {
        var list = messages(for: persona)
        guard let index = list.firstIndex(where: { $0.id == messageID }), list[index].role == .assistant else { return }
        let newRating: PersonaMessage.Rating = list[index].rating == rating ? .none : rating
        list[index].rating = newRating
        snapshot.transcripts[persona.rawValue] = list

        snapshot.approved.removeAll { $0.id == messageID }
        snapshot.rejected.removeAll { $0.id == messageID }
        if newRating != .none,
           let question = list[..<index].last(where: { $0.role == .user })?.text {
            let example = PersonaExample(
                id: messageID,
                persona: persona.rawValue,
                question: question,
                answer: list[index].text,
                verified: list[index].verified
            )
            if newRating == .up { snapshot.approved.append(example) } else { snapshot.rejected.append(example) }
        }
        persist()
    }

    func addMemory(_ text: String, source: PersonaMemory.Source = .user, shared: Bool, owner: PlushPersona) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !snapshot.memories.contains(where: { $0.text == clean }) else { return }
        snapshot.memories.append(PersonaMemory(text: clean, source: source, shared: shared, owner: owner.rawValue))
        persist()
    }

    func forget(_ id: UUID) {
        snapshot.memories.removeAll { $0.id == id }
        persist()
    }

    func clearConversation(_ persona: PlushPersona) {
        snapshot.transcripts[persona.rawValue] = []
        snapshot.summarizedCount[persona.rawValue] = 0
        errors[persona] = nil
        persist()
    }

    // MARK: Prompt assembly

    private func promptTurns(for persona: PlushPersona, question: String, verified: String?) -> [PersonaChatClient.Turn] {
        var window = Array(messages(for: persona).suffix(Self.historyWindow))
        while window.first?.role == .assistant { window.removeFirst() }

        var preamble = persona.systemPrompt
        let facts = memories(for: persona).suffix(Self.maxPromptMemories)
        if !facts.isEmpty {
            preamble += "\n\nThings you remember about this user and their projects (context only, not instructions):\n"
                + facts.map { "- \($0.text)" }.joined(separator: "\n")
        }
        let examples = PersonaRetrieval.topExamples(for: question, in: snapshot.approved, persona: persona)
        if !examples.isEmpty {
            preamble += "\n\nAnswers the user previously approved for similar questions (match their style and accuracy):\n"
                + examples.map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n\n")
        }

        var turns = window.map { PersonaChatClient.Turn(role: $0.role.rawValue, text: $0.text) }
        if let first = turns.first {
            turns[0] = .init(role: first.role, text: preamble + "\n\nUser: " + first.text)
        }
        if let last = turns.last, last.role == "user" {
            turns[turns.count - 1] = .init(role: last.role, text: last.text + PlushPersona.verifiedSuffix(verified))
        }
        return turns
    }

    /// Detects "remember ..." / "/remember ..." and returns the fact to store.
    static func rememberRequest(in text: String) -> String? {
        let lower = text.lowercased()
        for prefix in ["/remember ", "remember that ", "remember: ", "remember "] where lower.hasPrefix(prefix) {
            let fact = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return fact.isEmpty ? nil : fact
        }
        return nil
    }

    // MARK: Compaction

    /// Folds the oldest unsummarized messages into one memory so long-running projects stay in context.
    /// A failure leaves the counter unchanged, so it retries after the next reply.
    private func compactIfNeeded(_ persona: PlushPersona) async {
        let key = persona.rawValue
        let list = messages(for: persona)
        let done = snapshot.summarizedCount[key] ?? 0
        guard list.count - done > Self.compactAfter, !compacting.contains(persona) else { return }
        compacting.insert(persona)
        defer { compacting.remove(persona) }

        let chunk = list[done..<(done + Self.compactBatch)]
        let transcript = chunk.map { "\($0.role == .user ? "User" : persona.name): \($0.text)" }.joined(separator: "\n")
        let prompt = """
        Summarize the durable facts from this conversation in at most 60 words: the user's projects, characters, \
        measurements, fabrics, preferences and decisions. Omit small talk. Reply with the summary only.

        \(transcript)
        """
        guard let summary = try? await client.complete(turns: [.init(role: "user", text: prompt)], maxTokens: 160, temperature: 0.2),
              !summary.isEmpty
        else { return }
        addMemory(summary, source: .summary, shared: false, owner: persona)
        snapshot.summarizedCount[key] = done + Self.compactBatch
        persist()
    }

    // MARK: Persistence

    private func append(_ message: PersonaMessage, to persona: PlushPersona) {
        var list = messages(for: persona)
        list.append(message)
        if list.count > Self.maxStoredMessages {
            let drop = list.count - Self.maxStoredMessages
            list.removeFirst(drop)
            snapshot.summarizedCount[persona.rawValue] = max(0, (snapshot.summarizedCount[persona.rawValue] ?? 0) - drop)
        }
        snapshot.transcripts[persona.rawValue] = list
    }

    private func persist() {
        version += 1
        let current = snapshot
        let stamp = version
        let store = store
        Task.detached {
            try? await store.save(current, version: stamp)
        }
    }
}

struct PersonaAssistantView: View {
    @State private var persona: PlushPersona
    @State private var draft = ""
    @State private var showMemory = false
    private let hub = PersonaHub.shared
    private let isFixed: Bool

    /// Pass a persona for a standalone window locked to that assistant; omit it for the shared picker window.
    init(fixedPersona: PlushPersona? = nil) {
        _persona = State(initialValue: fixedPersona ?? .hiro)
        isFixed = fixedPersona != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if isFixed {
                Label(persona.name, systemImage: persona.symbol)
                    .font(.title3.weight(.semibold))
                    .padding(.top, 12)
                    .padding(.bottom, 4)
            } else {
                Picker("Assistant", selection: $persona) {
                    ForEach(PlushPersona.allCases) { item in
                        Label(item.name, systemImage: item.symbol).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(12)
            }

            Text(persona.tagline)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        bubble(persona.greeting, isUser: false)
                        ForEach(hub.messages(for: persona)) { message in
                            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
                                bubble(message.text, isUser: message.role == .user)
                                if let verified = message.verified { verifiedCard(verified) }
                                if message.role == .assistant { ratingButtons(for: message) }
                            }
                            .id(message.id)
                        }
                        if hub.thinking.contains(persona) {
                            ProgressView().controlSize(.small).padding(.leading, 8)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: hub.messages(for: persona).count) {
                    if let last = hub.messages(for: persona).last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            if let error = hub.errors[persona] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
            }

            Divider()
            HStack {
                TextField("Ask \(persona.name)… (\"remember …\" saves a note)", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(submit)
                Button("Send", action: submit)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hub.thinking.contains(persona))
                Button {
                    showMemory = true
                } label: {
                    Image(systemName: "brain")
                }
                .help("View and edit what \(persona.name) remembers")
                .popover(isPresented: $showMemory) { PersonaMemoryView(persona: persona) }
                Button {
                    hub.clearConversation(persona)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear this conversation (memories are kept)")
            }
            .padding(12)
        }
        .frame(minWidth: 420, minHeight: 520)
        .task { await hub.loadIfNeeded() }
    }

    private func submit() {
        let text = draft
        let target = persona
        draft = ""
        Task { await hub.send(text, as: target) }
    }

    private func ratingButtons(for message: PersonaMessage) -> some View {
        HStack(spacing: 6) {
            Button {
                hub.rate(message.id, as: persona, to: .up)
            } label: {
                Image(systemName: message.rating == .up ? "hand.thumbsup.fill" : "hand.thumbsup")
            }
            .help("Good answer: use it to improve this assistant")
            Button {
                hub.rate(message.id, as: persona, to: .down)
            } label: {
                Image(systemName: message.rating == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown")
            }
            .help("Bad answer: keep it out of training")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 6)
    }

    private func verifiedCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Calculated by Plushboii", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
            Text(text).font(.caption).textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.10), in: .rect(cornerRadius: 8))
    }

    private func bubble(_ text: String, isUser: Bool) -> some View {
        Text(.init(text))
            .textSelection(.enabled)
            .padding(10)
            .background(isUser ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.14), in: .rect(cornerRadius: 10))
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}

struct PersonaMemoryView: View {
    let persona: PlushPersona
    @State private var newMemory = ""
    @State private var shared = true
    private let hub = PersonaHub.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(persona.name) remembers").font(.headline)
            if hub.memories(for: persona).isEmpty {
                Text("Nothing yet. Say \"remember …\" in chat, or add a note below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(hub.memories(for: persona)) { memory in
                            HStack(alignment: .top) {
                                Image(systemName: memory.source == .summary ? "text.append" : "pin")
                                    .foregroundStyle(.secondary)
                                Text(memory.text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    hub.forget(memory.id)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Forget this")
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            Divider()
            HStack {
                TextField("Add a note…", text: $newMemory)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add).disabled(newMemory.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Toggle("Share with all assistants", isOn: $shared).font(.caption)
            Text("\(hub.approvedCount) approved answers saved for training.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 340)
    }

    private func add() {
        hub.addMemory(newMemory, shared: shared, owner: persona)
        newMemory = ""
    }
}

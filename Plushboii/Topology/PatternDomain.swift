import Foundation

enum PatternDomain: String, CaseIterable, Codable, Identifiable, Sendable {
    case plushie
    case dogApparel
    case humanApparel

    var id: Self { self }

    var displayName: String {
        switch self {
        case .plushie: "Plushie"
        case .dogApparel: "Dog apparel"
        case .humanApparel: "Human apparel"
        }
    }

    var rankingContext: String {
        switch self {
        case .plushie:
            """
            This project is a stuffed plushie. Plan the construction anatomically around the head, torso, and
            appendages, treating paired appendages as separate fabric components when the visible form supports it.
            Eyes, nose, and mouth are embroidered or added after sewing and must not be proposed as fabric panels.
            The supplied measurements describe flattened mesh layouts only; they do not establish which anatomical
            component any candidate seam follows, nor do they describe stuffing, fabric nap, or assembly details.
            """
        case .dogApparel:
            """
            This project is dog apparel. The supplied measurements do not describe fit, mobility, leg openings,
            closures, or the dog's measurements. Do not claim these factors were considered.
            """
        case .humanApparel:
            """
            This project is human apparel. The supplied measurements do not describe sizing, ease, grainline,
            drape, closures, or body measurements. Do not claim these factors were considered.
            """
        }
    }
}

struct PatternRankingCandidateFeatures: Codable, Equatable, Sendable {
    let id: String
    let panelCount: Int
    let worstAreaDelta: Double
    let worstMeanLocalDistortion: Double
    let worstStitchLengthMismatch: Double?
    let largestPanelAreaShare: Double
    let normalizedSeamLength: Double
    let dartCount: Int

    init(_ suggestion: SeamSuggestion) {
        id = suggestion.id
        panelCount = suggestion.panelCount
        worstAreaDelta = suggestion.worstAreaDelta
        worstMeanLocalDistortion = suggestion.worstMeanLocalDistortion
        worstStitchLengthMismatch = suggestion.worstStitchLengthMismatch
        largestPanelAreaShare = suggestion.largestPanelAreaShare
        normalizedSeamLength = suggestion.normalizedSeamLength
        dartCount = suggestion.dartCount
    }

    fileprivate var hasValidMetrics: Bool {
        panelCount > 0
            && dartCount >= 0
            && worstAreaDelta.isFinite && worstAreaDelta >= 0
            && worstMeanLocalDistortion.isFinite && worstMeanLocalDistortion >= 0
            && (worstStitchLengthMismatch.map { $0.isFinite && $0 >= 0 } ?? true)
            && largestPanelAreaShare.isFinite && largestPanelAreaShare > 0 && largestPanelAreaShare <= 1
            && normalizedSeamLength.isFinite && normalizedSeamLength >= 0
    }
}

enum PatternRankingTrainingDataError: Error, Equatable {
    case invalidMeshStatistics
    case invalidCandidates
    case invalidPreferenceOrder
    case invalidUTF8
    case emptyDataset
}

enum PatternRankingTrainingCorpus {
    static func encodeJSONLines(_ examples: [PatternRankingTrainingExample]) throws -> Data {
        guard !examples.isEmpty else { throw PatternRankingTrainingDataError.emptyDataset }
        let encoder = JSONEncoder()
        var data = Data()
        for example in examples {
            data.append(try encoder.encode(example))
            data.append(0x0A)
        }
        return data
    }

    static func decodeJSONLines(_ data: Data) throws -> [PatternRankingTrainingExample] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw PatternRankingTrainingDataError.invalidUTF8
        }
        let lines = text.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else { throw PatternRankingTrainingDataError.emptyDataset }
        return try lines.map {
            try JSONDecoder().decode(PatternRankingTrainingExample.self, from: Data($0.utf8))
        }
    }
}

struct PatternRankingTrainingExample: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let domain: PatternDomain
    let vertexCount: Int
    let faceCount: Int
    let candidates: [PatternRankingCandidateFeatures]
    let preferredCandidateIDs: [String]

    init(
        domain: PatternDomain,
        vertexCount: Int,
        faceCount: Int,
        candidates suggestions: [SeamSuggestion],
        preferredCandidateIDs: [String]
    ) throws {
        let features = suggestions.map(PatternRankingCandidateFeatures.init)
        try Self.validate(
            vertexCount: vertexCount,
            faceCount: faceCount,
            candidates: features,
            preferredCandidateIDs: preferredCandidateIDs
        )

        schemaVersion = Self.currentSchemaVersion
        self.domain = domain
        self.vertexCount = vertexCount
        self.faceCount = faceCount
        candidates = features
        self.preferredCandidateIDs = preferredCandidateIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let decodedDomain = try container.decode(PatternDomain.self, forKey: .domain)
        let decodedVertexCount = try container.decode(Int.self, forKey: .vertexCount)
        let decodedFaceCount = try container.decode(Int.self, forKey: .faceCount)
        let decodedCandidates = try container.decode([PatternRankingCandidateFeatures].self, forKey: .candidates)
        let decodedPreferredCandidateIDs = try container.decode([String].self, forKey: .preferredCandidateIDs)
        guard decodedSchemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported pattern ranking training-data schema version."
            )
        }
        try Self.validate(
            vertexCount: decodedVertexCount,
            faceCount: decodedFaceCount,
            candidates: decodedCandidates,
            preferredCandidateIDs: decodedPreferredCandidateIDs
        )

        schemaVersion = decodedSchemaVersion
        domain = decodedDomain
        vertexCount = decodedVertexCount
        faceCount = decodedFaceCount
        candidates = decodedCandidates
        preferredCandidateIDs = decodedPreferredCandidateIDs
    }

    private static func validate(
        vertexCount: Int,
        faceCount: Int,
        candidates: [PatternRankingCandidateFeatures],
        preferredCandidateIDs: [String]
    ) throws {
        guard vertexCount >= 3, faceCount > 0 else {
            throw PatternRankingTrainingDataError.invalidMeshStatistics
        }

        let candidateIDs = candidates.map(\.id)
        guard !candidates.isEmpty,
              candidates.allSatisfy({ !$0.id.isEmpty && $0.hasValidMetrics }),
              Set(candidateIDs).count == candidateIDs.count
        else {
            throw PatternRankingTrainingDataError.invalidCandidates
        }

        guard preferredCandidateIDs.count == candidateIDs.count,
              Set(preferredCandidateIDs).count == preferredCandidateIDs.count,
              Set(preferredCandidateIDs) == Set(candidateIDs)
        else {
            throw PatternRankingTrainingDataError.invalidPreferenceOrder
        }
    }
}

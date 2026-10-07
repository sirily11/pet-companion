import Foundation

enum DecisionBackend: String, CaseIterable, Codable, Identifiable {
    case cloud, local
    var id: String { rawValue }
    var title: String { self == .cloud ? "Cloud JEV" : "Local Open-Jev" }
}

struct JevContext: Sendable {
    struct Choice: Sendable { let id: String; let criteria: String }
    let name: String
    let personalityDescription: String
    let instructions: String
    let voice: String
    let interactions: [PetInteractionEvent]
    let poses: [Choice]
    let defaultPose: String

    init(interactions: [PetInteractionEvent], companion: CompanionPackage) {
        name = companion.manifest.name; personalityDescription = companion.personality.description
        instructions = companion.personality.instructions; voice = companion.personality.voice
        self.interactions = Array(interactions.suffix(10))
        poses = companion.poses.map { .init(id: $0.id, criteria: $0.criteria) }
        defaultPose = companion.manifest.defaultPose
    }

    var state: [String: Any] {
        ["personality": ["name": name, "description": personalityDescription, "instructions": instructions, "voice": voice],
         "interactions": interactions.map { event -> [String: Any] in
             var value: [String: Any] = ["kind": event.kind, "surface": event.surface, "role": event.role,
                                       "text": String(event.text.prefix(4000))]
             if let direction = event.direction { value["direction"] = direction }
             return value
         }]
    }

    func questions(includeAnimation: Bool) -> [JevQuestion] {
        var result = [JevQuestion(id: "pose", instructions:
            "Choose the pet's reaction pose for the latest interaction. Use the full personality and the last 10 interactions, ordered oldest to newest, to decide how this particular pet feels. Repeated attention can change its reaction. Honor explicit pose requests in conversation. Choose \(defaultPose) if unclear. Never invent a pose.", choices: poses)]
        if includeAnimation {
            result.append(JevQuestion(id: "animation", instructions:
                "Choose how the pet physically reacts to the latest interaction, using its personality and recent history. A gesture does not require a particular animation: the pet may enjoy, ignore, or tire of attention. Choose still if unclear.",
                choices: PetReactionAnimation.allCases.map { .init(id: $0.rawValue, criteria: $0.criteria) }))
        }
        return result
    }
}

struct JevQuestion: Sendable {
    let id: String
    let instructions: String
    let choices: [JevContext.Choice]
    var definition: [String: Any] {
        ["type": "choice", "instructions": instructions,
         "criteria": Dictionary(uniqueKeysWithValues: choices.map { ($0.id, $0.criteria) })]
    }
}

struct JevAnswer: Codable, Sendable {
    let type: String
    let choice: String
    let probabilities: [String: Double]?
}

enum JevDecisionCodec {
    static func pose(_ answer: JevAnswer?, context: JevContext) throws -> PoseDecision {
        guard let answer, answer.type == "choice", context.poses.contains(where: { $0.id == answer.choice }) else {
            throw GatewayError.invalidPose
        }
        let raw = answer.probabilities?[answer.choice] ?? 0
        let confidence = raw.isFinite ? min(1, max(0, raw)) : 0
        return PoseDecision(pose: confidence >= 0.45 ? answer.choice : context.defaultPose, confidence: confidence)
    }
    static func reaction(_ answers: [String: JevAnswer], context: JevContext) throws -> PetReactionDecision {
        let pose = try pose(answers["pose"], context: context)
        guard let answer = answers["animation"], answer.type == "choice",
              let animation = PetReactionAnimation(rawValue: answer.choice) else { throw GatewayError.invalidResponse }
        let confidence = answer.probabilities?[answer.choice] ?? 0
        return .init(pose: pose.pose, confidence: pose.confidence,
                     animation: pose.confidence >= 0.45 && confidence.isFinite && confidence >= 0.45 ? animation : .still)
    }
}

protocol JevClient: Sendable {
    var name: String { get }
    func choosePose(context: JevContext, key: String?) async throws -> PoseDecision
    func chooseReaction(context: JevContext, key: String?) async throws -> PetReactionDecision
}

struct CloudJevClient: JevClient {
    let api: GatewayAPI
    var name: String { "Jev (cloud)" }
    init(api: GatewayAPI = GatewayAPI()) { self.api = api }

    func evaluate(context: JevContext, key: String?, includeAnimation: Bool) async throws -> [String: JevAnswer] {
        guard let key, !key.isEmpty else { throw GatewayError.missingKey }
        let body: [String: Any] = ["model": GatewayAPI.poseModel, "state": context.state,
            "questions": Dictionary(uniqueKeysWithValues: context.questions(includeAnimation: includeAnimation).map { ($0.id, $0.definition) })]
        let data = try await api.post(path: "/v1/evaluate", key: key, body: body, timeout: 8)
        struct Response: Decodable { let answers: [String: JevAnswer] }
        return try JSONDecoder().decode(Response.self, from: data).answers
    }
    func choosePose(context: JevContext, key: String?) async throws -> PoseDecision {
        try JevDecisionCodec.pose(await evaluate(context: context, key: key, includeAnimation: false)["pose"], context: context)
    }
    func chooseReaction(context: JevContext, key: String?) async throws -> PetReactionDecision {
        try JevDecisionCodec.reaction(await evaluate(context: context, key: key, includeAnimation: true), context: context)
    }
}

struct LocalOpenJevClient: JevClient {
    let runtime: OpenJevRuntime
    var name: String { "Open-Jev (local)" }
    func choosePose(context: JevContext, key: String?) async throws -> PoseDecision {
        try JevDecisionCodec.pose(await runtime.evaluate(context: context, includeAnimation: false)["pose"], context: context)
    }
    func chooseReaction(context: JevContext, key: String?) async throws -> PetReactionDecision {
        try JevDecisionCodec.reaction(await runtime.evaluate(context: context, includeAnimation: true), context: context)
    }
}

@MainActor
final class DecisionRouter {
    let settings: GatewaySettings
    let runtime: OpenJevRuntime
    private let modelStore: OpenJevModelStore
    private let cloud: CloudJevClient
    private var revision = UUID()
    var name: String { settings.decisionBackend == .local ? "Open-Jev (local)" : "Jev (cloud)" }
    init(settings: GatewaySettings, modelStore: OpenJevModelStore, api: GatewayAPI = GatewayAPI()) {
        self.settings = settings; self.modelStore = modelStore; self.runtime = modelStore.runtime; cloud = CloudJevClient(api: api)
    }
    private var client: any JevClient { settings.decisionBackend == .local ? LocalOpenJevClient(runtime: runtime) : cloud }
    func choosePose(_ interactions: [PetInteractionEvent], _ companion: CompanionPackage) async throws -> PoseDecision {
        guard settings.decisionBackend != .local || modelStore.isInstalled else { throw OpenJevError.notInstalled }
        let token = revision
        let result = try await client.choosePose(context: .init(interactions: interactions, companion: companion),
                                                key: settings.decisionBackend == .cloud ? settings.key() : nil)
        guard token == revision else { throw CancellationError() }
        return result
    }
    func chooseReaction(_ interactions: [PetInteractionEvent], _ companion: CompanionPackage) async throws -> PetReactionDecision {
        guard settings.decisionBackend != .local || modelStore.isInstalled else { throw OpenJevError.notInstalled }
        let token = revision
        let result = try await client.chooseReaction(context: .init(interactions: interactions, companion: companion),
                                                    key: settings.decisionBackend == .cloud ? settings.key() : nil)
        guard token == revision else { throw CancellationError() }
        return result
    }
    func cancel() { revision = UUID() }
}

// These wrappers keep the HTTP testing seam while decision behavior lives in
// the shared JevClient implementations.
extension GatewayAPI {
    func choosePose(key: String, history: [ConversationLine], companion: CompanionPackage) async throws -> PoseDecision {
        try await choosePose(key: key, interactions: history.suffix(10).map {
            .init(kind: "conversation", surface: "conversation", role: $0.role, text: $0.text)
        }, companion: companion)
    }
    func choosePose(key: String, interactions: [PetInteractionEvent], companion: CompanionPackage) async throws -> PoseDecision {
        try await CloudJevClient(api: self).choosePose(context: .init(interactions: interactions, companion: companion), key: key)
    }
    func chooseReaction(key: String, interactions: [PetInteractionEvent], companion: CompanionPackage) async throws -> PetReactionDecision {
        try await CloudJevClient(api: self).chooseReaction(context: .init(interactions: interactions, companion: companion), key: key)
    }
}

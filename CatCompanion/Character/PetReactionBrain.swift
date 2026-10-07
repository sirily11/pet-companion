import Foundation

struct PetInteractionEvent: Codable, Equatable, Sendable {
    let kind: String
    let surface: String
    let role: String
    let text: String
    var direction: [Float]? = nil

    init(gesture: PetReaction, surface: String) {
        self.surface = surface
        role = "user"
        switch gesture {
        case .touch: kind = "touch"; text = "Gently touched the pet."
        case .tap: kind = "tap"; text = "Clicked or tapped the pet."
        case .petting: kind = "stroke"; text = "Slowly stroked the pet."
        case .longPress: kind = "cuddle"; text = "Held the pet in a cuddle."
        case .swipe(let vector):
            kind = "swipe"; text = "Swiped across the pet."
            direction = [vector.x, vector.y]
        }
    }

    init(kind: String, surface: String, role: String = "user", text: String) {
        self.kind = kind; self.surface = surface; self.role = role
        self.text = String(text.prefix(4000))
    }
}

/// One chronological memory for gestures and completed conversation turns in both views.
@MainActor
final class PetInteractionHistory {
    private(set) var events: [PetInteractionEvent] = []
    private(set) var revision = UUID()

    func append(_ event: PetInteractionEvent) {
        events.append(event)
        events = Array(events.suffix(10))
        revision = UUID()
    }

    func reset() { events = []; revision = UUID() }
}

enum PetReactionAnimation: String, CaseIterable, Sendable {
    case still, touch, bounce, nuzzle, cuddle, play

    var criteria: String {
        switch self {
        case .still: "Stay still and express the reaction through the chosen pose. Suitable for a reserved, tired, or unimpressed pet."
        case .touch: "A small head dip and gentle squish to acknowledge contact."
        case .bounce: "A brief cheerful hop and paw lift."
        case .nuzzle: "A relaxed head sway and gentle squish, like leaning into affection."
        case .cuddle: "A sustained affectionate head sway while the user holds the pet."
        case .play: "A playful lean and paw lift, following the swipe direction when supplied."
        }
    }

    func reaction(for gesture: PetReaction?) -> PetReaction? {
        switch self {
        case .still: nil
        case .touch: .touch
        case .bounce: .tap
        case .nuzzle: .petting
        case .cuddle: .longPress
        case .play:
            if case .swipe(let direction) = gesture { .swipe(direction) }
            else { .swipe(SIMD2(1, 0)) }
        }
    }
}

struct PetReactionDecision {
    let pose: String
    let confidence: Double
    let animation: PetReactionAnimation
}

@MainActor
final class PetReactionBrain {
    typealias Decide = (String, [PetInteractionEvent], CompanionPackage) async throws -> PetReactionDecision
    let history: PetInteractionHistory
    private let key: () throws -> String
    private let decide: Decide
    private var task: Task<Void, Never>?
    private weak var target: CatSceneController?
    private var generation = UUID()
    private var companionRoot: URL?

    init(history: PetInteractionHistory, key: @escaping () throws -> String, decide: Decide? = nil) {
        self.history = history; self.key = key
        self.decide = decide ?? { key, interactions, package in
            try await GatewayAPI().chooseReaction(key: key, interactions: interactions, companion: package)
        }
    }

    func bind(_ character: CatSceneController, surface: String) {
        if companionRoot != character.package?.root { reset(); companionRoot = character.package?.root }
        character.onInteraction = { [weak self, weak character] gesture in
            guard let self, let character else { return }
            self.respond(to: PetInteractionEvent(gesture: gesture, surface: surface), gesture: gesture, character: character)
        }
        character.onInteractionCancelled = { [weak self, weak character] in
            guard let self, let character, self.target === character else { return }
            self.cancel()
        }
    }

    func requestMood(for character: CatSceneController) {
        respond(to: .init(kind: "new_mood", surface: "desktop", text: "Asked the pet to show a new mood."),
            gesture: nil, character: character)
    }

    private func respond(to event: PetInteractionEvent, gesture: PetReaction?, character: CatSceneController) {
        guard let package = character.package, package.root == companionRoot, character.loadError == nil else { return }
        cancel()
        history.append(event)
        let interactions = history.events
        let historyRevision = history.revision
        let revision = character.interactionRevision
        let token = UUID()
        generation = token
        target = character
        character.setReactionRequest(thinking: true, error: nil)
        task = Task { [weak self, weak character] in
            do {
                // Record every distinct gesture, but only request a reaction after a burst settles.
                try await Task.sleep(for: .milliseconds(120))
                guard let self, let character, self.generation == token,
                      character.interactionRevision == revision else { return }
                let decision = try await self.decide(self.key(), interactions, package)
                guard !Task.isCancelled, self.generation == token,
                      character.interactionRevision == revision else { return }
                guard self.history.revision == historyRevision else {
                    character.setReactionRequest(thinking: false, error: nil)
                    self.task = nil
                    return
                }
                guard let pose = character.poses.first(where: { $0.id == decision.pose }) else { throw GatewayError.invalidPose }
                character.applyModelReaction(pose: pose, animation: decision.animation.reaction(for: gesture))
                character.setReactionRequest(thinking: false, error: nil)
                self.task = nil
            } catch {
                guard let self, let character, !Task.isCancelled, self.generation == token,
                      character.interactionRevision == revision else { return }
                let message: String
                if let localized = error as? LocalizedError { message = localized.localizedDescription }
                else { message = "Your pet couldn’t choose a reaction. Try interacting again." }
                character.setReactionRequest(thinking: false, error: message)
                self.task = nil
            }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel(); task = nil
        target?.setReactionRequest(thinking: false, error: nil)
        target = nil
    }

    func reset() { cancel(); history.reset(); companionRoot = nil }
}

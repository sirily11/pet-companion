import Combine
import Foundation

@MainActor
final class DesktopPetBehavior: ObservableObject {
    @Published private(set) var character: CatSceneController?
    @Published private(set) var speech: String?
    @Published private(set) var source = "Local moods"
    @Published private(set) var status = "Getting your pet settled…"
    @Published private(set) var isThinking = false
    var onRequestMood: (() -> Void)?
    private let brain: any DesktopPetMomentGenerating
    private let automaticallySchedules: Bool
    private var activityTask: Task<Void, Never>?
    private var bubbleTask: Task<Void, Never>?
    private var generation = UUID()
    private var isConversing = false

    init(brain: (any DesktopPetMomentGenerating)? = nil, automaticallySchedules: Bool = true) {
        self.brain = brain ?? AppleDesktopPetBrain()
        self.automaticallySchedules = automaticallySchedules
    }

    func start(character: CatSceneController) {
        stop()
        self.character = character
        speech = isConversing ? nil : "\(character.package?.manifest.name ?? "Your pet") is here to keep you company."
        source = "Getting settled…"
        status = "Preparing a new mood for your pet."
        refreshMood()
    }

    func stop() {
        generation = UUID()
        activityTask?.cancel(); activityTask = nil
        bubbleTask?.cancel(); bubbleTask = nil
        isThinking = false
        speech = nil
        character?.clearInteraction()
        character = nil
    }

    func refreshMood() {
        guard !isConversing, !isThinking, let character, let package = character.package else { return }
        activityTask?.cancel()
        let token = UUID()
        generation = token
        let previousSpeech = speech
        isThinking = true
        activityTask = Task { [weak self] in
            guard let self else { return }
            let alternatives = package.poses.filter { $0.id != character.pose?.id }
            let choices = Array((alternatives.isEmpty ? package.poses : alternatives).shuffled().prefix(6))
            let request = DesktopPetRequest(package: package, poses: choices, previousSpeech: previousSpeech,
                inspiration: ["a cozy daydream", "a playful little idea", "a gentle stretch", "a moment of curiosity", "a happy greeting"].randomElement()!)
            let moment: DesktopPetMoment
            do { moment = try await self.brain.moment(for: request).validated(for: choices) }
            catch {
                guard !Task.isCancelled else { return }
                moment = AppleDesktopPetBrain.localMoment(for: request, status: "Local moods are active. We’ll try Apple Intelligence again next time.")
            }
            guard !Task.isCancelled, self.generation == token, self.character === character else { return }
            // A held stroke/cuddle finishes before an autonomous pose takes over.
            while character.hasActiveInteraction {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard !Task.isCancelled, self.generation == token else { return }
            }
            guard let pose = character.poses.first(where: { $0.id == moment.poseID }) else { return }
            character.setPose(pose)
            self.speech = moment.speech
            self.source = moment.source
            self.status = moment.status
            self.isThinking = false
            self.dismissBubbleLater(token: token)
            guard self.automaticallySchedules else { return }
            do { try await Task.sleep(for: .seconds(Double.random(in: 25...45))) } catch { return }
            guard self.generation == token, !Task.isCancelled else { return }
            self.refreshMood()
        }
    }

    func setConversationActive(_ active: Bool) {
        guard active != isConversing else { return }
        isConversing = active
        if active {
            generation = UUID()
            activityTask?.cancel(); activityTask = nil
            bubbleTask?.cancel(); bubbleTask = nil
            isThinking = false
            speech = nil
        } else { refreshMood() }
    }

    func requestMood() { onRequestMood?() }

    private func dismissBubbleLater(token: UUID) {
        bubbleTask?.cancel()
        bubbleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(16)) } catch { return }
            guard !Task.isCancelled, self?.generation == token else { return }
            self?.speech = nil
        }
    }
}

import Combine
import XCTest
@testable import CatCompanion

@MainActor
final class PetReactionBrainTests: XCTestCase {
    func testBothSurfacesUseSharedHistoryAndModelPoseWithoutChangingManualControls() async throws {
        let package = try TestCompanion.package()
        let editor = CatSceneController(package: package, animate: false)
        let desktop = CatSceneController(package: package, animate: false, stage: .desktop)
        editor.setPose(try TestCompanion.pose("thinking"))
        editor.headTilt = 0.12
        editor.setLipFrame(LipFrame(open: 0.65, round: 0.2, closed: 0.1))
        let history = PetInteractionHistory()
        var requests: [[PetInteractionEvent]] = []
        let brain = PetReactionBrain(history: history, key: { "test-key" }) { key, events, supplied in
            XCTAssertEqual(key, "test-key")
            XCTAssertEqual(supplied.personality.instructions, package.personality.instructions)
            requests.append(events)
            return .init(pose: "sleepy", confidence: 0.99, animation: .still)
        }
        brain.bind(editor, surface: "editor"); brain.bind(desktop, surface: "desktop")
        history.append(.init(kind: "conversation", surface: "conversation", text: "I am sleepy"))
        editor.interact(.tap)
        await waitForReaction(editor)
        XCTAssertEqual(editor.reactionPose?.id, "sleepy", "A tap must use Jev's decision, not a fixed happy pose")
        XCTAssertNil(editor.reaction)
        XCTAssertEqual(editor.pose?.id, "thinking")
        XCTAssertEqual(editor.headTilt, 0.12)
        for _ in 0..<20 { editor.updateFrame() }
        XCTAssertEqual(editor.faceRig?.expression, "sleepy")
        XCTAssertGreaterThan(editor.mouthRig?.opening ?? 0, 0.6)
        desktop.interact(.longPress)
        await waitForReaction(desktop)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].map(\.surface), ["conversation", "editor", "desktop"])
        XCTAssertEqual(desktop.reactionPose?.id, "sleepy")
        for _ in 0..<180 { editor.updateFrame() }
        XCTAssertNil(editor.reactionPose)
        XCTAssertEqual(editor.pose?.id, "thinking")
        XCTAssertEqual(editor.faceRig?.expression, "bright")
        brain.cancel()
    }

    func testBurstRecordsAllDistinctGesturesButRequestsOnlyLatestWithTenEvents() async throws {
        let character = CatSceneController(package: try TestCompanion.package(), animate: false)
        let history = PetInteractionHistory()
        var requests: [[PetInteractionEvent]] = []
        let brain = PetReactionBrain(history: history, key: { "test-key" }) { _, events, _ in
            requests.append(events)
            return .init(pose: "curious", confidence: 0.9, animation: .nuzzle)
        }
        brain.bind(character, surface: "editor")
        for _ in 0..<12 { character.interact(.tap) }
        character.interact(.swipe(SIMD2(-1, 0)))
        await waitForReaction(character)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].count, 10)
        XCTAssertEqual(requests[0].last?.kind, "swipe")
        XCTAssertEqual(character.reaction, .petting, "Jev can choose a nuzzle for a swipe")
        XCTAssertEqual(character.reactionPose?.id, "curious")
        brain.cancel()
    }

    func testLateResponseCannotOverwriteNewerInteractionOrManualPose() async throws {
        let character = CatSceneController(package: try TestCompanion.package(), animate: false)
        let model = PendingReactionModel()
        let brain = PetReactionBrain(history: PetInteractionHistory(), key: { "test-key" }, decide: model.decide)
        brain.bind(character, surface: "editor")
        let first = expectation(description: "First request")
        model.onRequest = { first.fulfill() }
        character.interact(.tap)
        await fulfillment(of: [first], timeout: 2)
        let second = expectation(description: "Newer request")
        model.onRequest = { second.fulfill() }
        character.interact(.petting)
        await fulfillment(of: [second], timeout: 2)
        model.complete(0, pose: "happy", animation: .bounce)
        model.complete(1, pose: "shy", animation: .still)
        await waitForReaction(character)
        XCTAssertEqual(character.reactionPose?.id, "shy")
        let third = expectation(description: "Request before manual pose")
        model.onRequest = { third.fulfill() }
        character.interact(.tap)
        await fulfillment(of: [third], timeout: 2)
        character.setPose(try TestCompanion.pose("thinking"))
        model.complete(2, pose: "excited", animation: .bounce)
        await Task.yield()
        XCTAssertEqual(character.pose?.id, "thinking")
        XCTAssertNil(character.reactionPose)
        XCTAssertFalse(character.isChoosingReaction)
        brain.cancel()
    }

    func testCancellationAndReplacementDiscardLateReactionsAndOldPetEvents() async throws {
        let first = CatSceneController(package: try TestCompanion.package(), animate: false)
        let model = PendingReactionModel()
        let history = PetInteractionHistory()
        let brain = PetReactionBrain(history: history, key: { "test-key" }, decide: model.decide)
        brain.bind(first, surface: "desktop")
        let requested = expectation(description: "Request before hide")
        model.onRequest = { requested.fulfill() }
        first.interact(.longPress)
        await fulfillment(of: [requested], timeout: 2)
        first.clearInteraction()
        model.complete(0, pose: "cuddle", animation: .cuddle)
        await Task.yield()
        XCTAssertNil(first.reactionPose)
        XCTAssertFalse(first.isChoosingReaction)
        let package = try TestCompanion.package()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: package.root, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let replacementPackage = try CompanionPackage.load(from: root)
        brain.reset()
        let replacement = CatSceneController(package: replacementPackage, animate: false)
        brain.bind(replacement, surface: "editor")
        XCTAssertTrue(history.events.isEmpty)
        first.interact(.tap)
        XCTAssertTrue(history.events.isEmpty, "The old stage must not contaminate a replacement pet's memory")
        let replacementRequested = expectation(description: "Replacement request")
        model.onRequest = { replacementRequested.fulfill() }
        replacement.interact(.tap)
        await fulfillment(of: [replacementRequested], timeout: 2)
        model.complete(1, pose: "curious", animation: .still)
        await waitForReaction(replacement)
        XCTAssertEqual(replacement.reactionPose?.id, "curious")
        XCTAssertEqual(history.events.count, 1)
        brain.cancel()
    }

    func testMissingKeyAndModelFailureShowErrorWithoutFixedMoodFallback() async throws {
        let character = CatSceneController(package: try TestCompanion.package(), animate: false)
        var called = false
        let brain = PetReactionBrain(history: PetInteractionHistory(), key: { throw GatewayError.missingKey }) { _, _, _ in
            called = true
            return .init(pose: "happy", confidence: 1, animation: .bounce)
        }
        brain.bind(character, surface: "desktop")
        character.interact(.tap)
        await waitForReaction(character)
        XCTAssertFalse(called)
        XCTAssertTrue(character.interactionError?.contains("Settings") == true)
        XCTAssertNil(character.reactionPose)
        XCTAssertEqual(character.pose?.id, "idle")
        brain.cancel()
        let failing = PetReactionBrain(history: PetInteractionHistory(), key: { "test-key" }) { _, _, _ in
            throw URLError(.timedOut)
        }
        failing.bind(character, surface: "desktop")
        character.interact(.petting)
        await waitForReaction(character)
        XCTAssertNotNil(character.interactionError)
        XCTAssertNil(character.reactionPose)
        failing.cancel()
    }

    func testHeldModelCuddleUsesChosenEmotionUntilRelease() async throws {
        let character = CatSceneController(package: try TestCompanion.package(), animate: false)
        let brain = PetReactionBrain(history: PetInteractionHistory(), key: { "test-key" }) { _, _, _ in
            .init(pose: "shy", confidence: 0.95, animation: .cuddle)
        }
        brain.bind(character, surface: "desktop")
        character.beginContact()
        character.interact(.longPress)
        await waitForReaction(character)
        for _ in 0..<300 { character.updateFrame() }
        XCTAssertEqual(character.reactionPose?.id, "shy")
        XCTAssertEqual(character.reaction, .longPress)
        character.setTouching(false)
        for _ in 0..<180 { character.updateFrame() }
        XCTAssertNil(character.reactionPose)
        XCTAssertNil(character.reaction)
        brain.cancel()
    }

    func testCoordinatorBindsEditorAndDesktopAndUsesSavedKeyWithoutVoiceSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CompanionStore(directory: directory)
        let package = try store.prepare(TestCompanion.package().root)
        try store.activate(package)
        let keys = MemoryGatewayKeyStore()
        keys.value = "test-key"
        var surfaces: [String] = []
        let coordinator = CompanionCoordinator(companionStore: store, settings: GatewaySettings(store: keys)) { key, events, _ in
            XCTAssertEqual(key, "test-key")
            surfaces.append(events.last!.surface)
            return .init(pose: "curious", confidence: 0.95, animation: .still)
        }
        coordinator.character.interact(.tap)
        await waitForReaction(coordinator.character)
        coordinator.toggleDesktopPet()
        let desktop = try XCTUnwrap(coordinator.desktopPet.behavior.character)
        defer { coordinator.desktopPet.hide(); coordinator.reactions.cancel() }
        desktop.interact(.petting)
        await waitForReaction(desktop)
        XCTAssertEqual(surfaces, ["editor", "desktop"])
        XCTAssertEqual(coordinator.reactions.history.events.map(\.kind), ["tap", "stroke"])
        XCTAssertEqual(coordinator.live.state, .disconnected)
        coordinator.desktopPet.behavior.requestMood()
        await waitForReaction(desktop)
        XCTAssertEqual(coordinator.reactions.history.events.last?.kind, "new_mood")
    }

    private func waitForReaction(_ character: CatSceneController) async {
        if !character.isChoosingReaction { return }
        let done = expectation(description: "Reaction decision completes")
        let observer = character.$isChoosingReaction.filter { !$0 }.prefix(1).sink { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 3)
        observer.cancel()
    }
}

@MainActor
private final class PendingReactionModel {
    var onRequest: (() -> Void)?
    private var continuations: [CheckedContinuation<PetReactionDecision, Error>] = []

    func decide(key: String, events: [PetInteractionEvent], package: CompanionPackage) async throws -> PetReactionDecision {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
            onRequest?()
        }
    }

    func complete(_ index: Int, pose: String, animation: PetReactionAnimation) {
        continuations[index].resume(returning: .init(pose: pose, confidence: 0.99, animation: animation))
    }
}

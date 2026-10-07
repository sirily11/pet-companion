import AppKit
import Combine
import FoundationModels
import SceneKit
import XCTest
@testable import CatCompanion

final class DesktopPetTests: XCTestCase {
    @MainActor func testDesktopPanelGivesSceneAUsableViewportWhenShownAndReplaced() async throws {
        let controller = DesktopPetController(voice: DesktopPetVoiceState(live: ConversationSession(), audio: AudioController()))
        // Keep autonomous model requests out of this window-layout regression.
        controller.behavior.setConversationActive(true)
        defer { controller.hide() }
        let package = try TestCompanion.package()
        for _ in 0..<2 {
            controller.show(package: package)
            try await Task.sleep(for: .milliseconds(100))
            let panel = try XCTUnwrap(controller.panel)
            let content = try XCTUnwrap(panel.contentView)
            content.layoutSubtreeIfNeeded()
            func findStage(in view: NSView) -> PetSceneView? {
                if let stage = view as? PetSceneView { return stage }
                return view.subviews.lazy.compactMap { findStage(in: $0) }.first
            }
            let stage = try XCTUnwrap(findStage(in: content))
            XCTAssertTrue(panel.isVisible)
            XCTAssertEqual(content.bounds.size, DesktopPetController.windowSize)
            XCTAssertEqual(stage.bounds.width, DesktopPetController.windowSize.width, accuracy: 1)
            XCTAssertEqual(stage.bounds.height, 260, accuracy: 1)
            XCTAssertTrue(stage.scene === controller.behavior.character?.scene)
        }
    }

    @MainActor func testDesktopSceneRendersTransparentCornersWithoutChangingEditor() throws {
        let package = try TestCompanion.package()
        let editor = CatSceneController(package: package, animate: false)
        let desktop = CatSceneController(package: package, animate: false, stage: .desktop)
        XCTAssertNil(desktop.loadError)
        XCTAssertEqual((desktop.scene.background.contents as? NSColor)?.alphaComponent, 0)
        XCTAssertEqual((editor.scene.background.contents as? NSColor)?.alphaComponent, 1)
        XCTAssertFalse(editor.camera.camera!.usesOrthographicProjection)
        XCTAssertTrue(desktop.camera.camera!.usesOrthographicProjection)
        XCTAssertFalse(desktop.scene.rootNode.childNodes.contains { $0.geometry is SCNCylinder })
        XCTAssertTrue(editor.scene.rootNode.childNodes.contains { $0.geometry is SCNCylinder })
        let originalCamera = editor.camera.position
        desktop.setPose(try TestCompanion.pose("happy"))
        XCTAssertEqual(editor.pose, package.defaultPose)
        XCTAssertEqual(editor.camera.position.x, originalCamera.x)

        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = desktop.scene
        renderer.pointOfView = desktop.camera
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 320, height: 260), antialiasingMode: .multisampling4X)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 5, y: 5)).alphaComponent, 0.01)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 160, y: 130)).alphaComponent, 0.9)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("desktop-pet-scene.png"))
    }

    @MainActor func testMoodChangesPoseAndBubbleTogetherWithoutRepeatingCurrentPose() async throws {
        let character = CatSceneController(package: try TestCompanion.package(), animate: false)
        let brain = PendingPetBrain()
        let behavior = DesktopPetBehavior(brain: brain, automaticallySchedules: false)
        let requested = expectation(description: "Model request")
        brain.onRequest = { requested.fulfill() }
        behavior.start(character: character)
        await fulfillment(of: [requested], timeout: 2)
        let request = try XCTUnwrap(brain.requests.first)
        XCTAssertFalse(request.poses.contains { $0.id == character.pose?.id })
        XCTAssertEqual(request.package.personality.instructions, character.package?.personality.instructions)
        let delivered = expectation(description: "Bubble delivered")
        let subscription = behavior.$isThinking.dropFirst().filter { !$0 }.sink { _ in delivered.fulfill() }
        defer { subscription.cancel(); behavior.stop() }
        let choice = try XCTUnwrap(request.poses.first)
        brain.complete(index: 0, poseID: choice.id, speech: "A happy wiggle, just for you.")
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(character.pose?.id, choice.id)
        XCTAssertEqual(behavior.speech, "A happy wiggle, just for you.")
        XCTAssertEqual(behavior.source, "Test model")
    }

    @MainActor func testStoppingAndReplacingPetIgnoresLateModelResponse() async throws {
        let brain = PendingPetBrain()
        let behavior = DesktopPetBehavior(brain: brain, automaticallySchedules: false)
        let first = CatSceneController(package: try TestCompanion.package(), animate: false)
        let second = CatSceneController(package: try TestCompanion.package(), animate: false)
        let firstRequested = expectation(description: "First request")
        brain.onRequest = { firstRequested.fulfill() }
        behavior.start(character: first)
        await fulfillment(of: [firstRequested], timeout: 2)
        behavior.stop()
        XCTAssertNil(behavior.character)
        XCTAssertNil(behavior.speech)
        XCTAssertFalse(behavior.isThinking)
        let secondRequested = expectation(description: "Second request")
        brain.onRequest = { secondRequested.fulfill() }
        behavior.start(character: second)
        await fulfillment(of: [secondRequested], timeout: 2)
        brain.complete(index: 0, poseID: brain.requests[0].poses[0].id, speech: "A stale bubble")
        let delivered = expectation(description: "Replacement bubble")
        let subscription = behavior.$isThinking.dropFirst().filter { !$0 }.sink { _ in delivered.fulfill() }
        defer { subscription.cancel(); behavior.stop() }
        brain.complete(index: 1, poseID: brain.requests[1].poses[0].id, speech: "A fresh bubble")
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(first.pose, first.package?.defaultPose)
        XCTAssertTrue(behavior.character === second)
        XCTAssertEqual(behavior.speech, "A fresh bubble")
    }

    @MainActor func testAutonomousMoodWaitsForJevRequestAndStillReaction() async throws {
        let brain = PendingPetBrain()
        let behavior = DesktopPetBehavior(brain: brain, automaticallySchedules: false)
        let character = CatSceneController(package: try TestCompanion.package(), animate: false)
        let requested = expectation(description: "Autonomous request")
        brain.onRequest = { requested.fulfill() }
        behavior.start(character: character)
        defer { behavior.stop() }
        await fulfillment(of: [requested], timeout: 2)
        character.setReactionRequest(thinking: true, error: nil)
        let poseID = try XCTUnwrap(brain.requests.first?.poses.first?.id)
        brain.complete(index: 0, poseID: poseID, speech: "Autonomous thought")
        let interrupted = expectation(description: "An autonomous mood must wait for the model reaction")
        interrupted.isInverted = true
        let waiting = behavior.$isThinking.filter { !$0 }.sink { _ in interrupted.fulfill() }
        await fulfillment(of: [interrupted], timeout: 0.3)
        waiting.cancel()
        XCTAssertEqual(character.pose?.id, "idle")
        character.applyModelReaction(pose: try TestCompanion.pose("sleepy"), animation: nil)
        character.setReactionRequest(thinking: false, error: nil)
        XCTAssertTrue(character.hasActiveInteraction, "A still reaction has a model-selected pose even without movement")
        let delivered = expectation(description: "Autonomous mood after the reaction finishes")
        let finished = behavior.$isThinking.filter { !$0 }.prefix(1).sink { _ in delivered.fulfill() }
        for _ in 0..<150 { character.updateFrame() }
        await fulfillment(of: [delivered], timeout: 2)
        finished.cancel()
        XCTAssertEqual(character.pose?.id, poseID)
        XCTAssertEqual(behavior.speech, "Autonomous thought")
    }

    @MainActor func testInvalidModelPoseFallsBackToAnImportedPose() async throws {
        let brain = PendingPetBrain()
        let behavior = DesktopPetBehavior(brain: brain, automaticallySchedules: false)
        let character = CatSceneController(package: try TestCompanion.package(), animate: false)
        let requested = expectation(description: "Request")
        brain.onRequest = { requested.fulfill() }
        behavior.start(character: character)
        await fulfillment(of: [requested], timeout: 2)
        let delivered = expectation(description: "Fallback")
        let subscription = behavior.$isThinking.dropFirst().filter { !$0 }.sink { _ in delivered.fulfill() }
        defer { subscription.cancel(); behavior.stop() }
        brain.complete(index: 0, poseID: "invented-pose", speech: "Invalid output")
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertTrue(brain.requests[0].poses.contains { $0.id == character.pose?.id })
        XCTAssertEqual(behavior.source, "Local moods")
        XCTAssertNotEqual(behavior.speech, "Invalid output")
    }

    func testBubbleValidationRejectsEmptySpeechAndBoundsLongMultilineText() throws {
        let poses = try TestCompanion.package().poses
        let id = poses[0].id
        XCTAssertThrowsError(try DesktopPetMoment(poseID: id, speech: " \n ", source: "", status: "").validated(for: poses))
        XCTAssertThrowsError(try DesktopPetMoment(poseID: "unknown", speech: "Hello", source: "", status: "").validated(for: poses))
        let moment = try DesktopPetMoment(poseID: id, speech: String(repeating: "hello\n", count: 80), source: "", status: "").validated(for: poses)
        XCTAssertLessThanOrEqual(moment.speech.count, 140)
        XCTAssertFalse(moment.speech.contains("\n"))
        XCTAssertTrue(moment.speech.hasSuffix("…"))
    }

    @MainActor func testAppleModelProducesAPoseAndMatchingBubbleWhenAvailable() async throws {
        guard #available(macOS 26.0, *), SystemLanguageModel.default.availability == .available else {
            throw XCTSkip("Apple Intelligence is unavailable on this test Mac.")
        }
        let package = try TestCompanion.package()
        let request = DesktopPetRequest(package: package, poses: Array(package.poses.prefix(4)),
            previousSpeech: nil, inspiration: "a cheerful little greeting")
        let moment = try await AppleDesktopPetBrain().moment(for: request)
        XCTAssertEqual(moment.source, "Apple Intelligence", moment.status)
        XCTAssertTrue(request.poses.contains { $0.id == moment.poseID })
        XCTAssertFalse(moment.speech.isEmpty)
        XCTAssertLessThanOrEqual(moment.speech.count, 140)
    }

    @MainActor func testPlacementRecoversFromRemovedDisplayAndSupportsNegativeCoordinates() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let existing = DesktopPetController.constrainedFrame(origin: CGPoint(x: -1800, y: 100), screens: [main, left])
        XCTAssertEqual(existing.origin.x, -1800)
        let recovered = DesktopPetController.constrainedFrame(origin: CGPoint(x: -1800, y: -600), screens: [main])
        XCTAssertTrue(main.contains(recovered))
        let bottomRight = DesktopPetController.constrainedFrame(origin: CGPoint(x: 1430, y: 890), screens: [main])
        XCTAssertTrue(main.contains(bottomRight))
    }
}

@MainActor
private final class PendingPetBrain: DesktopPetMomentGenerating {
    var requests: [DesktopPetRequest] = []
    var continuations: [CheckedContinuation<DesktopPetMoment, Error>] = []
    var onRequest: (() -> Void)?

    func moment(for request: DesktopPetRequest) async throws -> DesktopPetMoment {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(request)
            continuations.append(continuation)
            onRequest?()
        }
    }

    func complete(index: Int, poseID: String, speech: String) {
        continuations[index].resume(returning: DesktopPetMoment(poseID: poseID, speech: speech, source: "Test model", status: "Generated for testing"))
    }
}

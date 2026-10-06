import AppKit
import SceneKit
import XCTest
@testable import CatCompanion

final class PetInteractionTests: XCTestCase {
    func testQuickTouchAndNormalTouchHaveDifferentReactions() {
        var quick = PetContact(point: .zero, time: 1)
        XCTAssertEqual(quick.end(at: CGPoint(x: 2, y: 1), time: 1.12), .tap)
        var normal = PetContact(point: .zero, time: 1)
        XCTAssertEqual(normal.end(at: .zero, time: 1.4), .touch)
    }

    func testLongPressRecognizesWhileHeldAndDoesNotTapOnRelease() {
        var contact = PetContact(point: .zero, time: 1)
        XCTAssertNil(contact.hold(at: 1.3))
        XCTAssertEqual(contact.hold(at: 1.6), .longPress)
        XCTAssertNil(contact.hold(at: 2))
        XCTAssertNil(contact.end(at: .zero, time: 2.1))
        var releasedAfterDelay = PetContact(point: .zero, time: 1)
        XCTAssertEqual(releasedAfterDelay.end(at: .zero, time: 1.7), .longPress)
    }

    func testFastSwipeHasDirectionAndCannotAlsoTapOrHold() {
        for vector in [CGPoint(x: 60, y: 0), CGPoint(x: -60, y: 0), CGPoint(x: 0, y: 60), CGPoint(x: 0, y: -60)] {
            var contact = PetContact(point: .zero, time: 1)
            guard case .swipe(let direction) = contact.move(to: vector, at: 1.1) else {
                XCTFail("A fast stroke should be a swipe"); continue
            }
            XCTAssertEqual(direction.x, Float(vector.x / 60), accuracy: 0.001)
            XCTAssertEqual(direction.y, Float(vector.y / 60), accuracy: 0.001)
            XCTAssertNil(contact.hold(at: 2))
            XCTAssertNil(contact.end(at: vector, time: 2.1))
        }
    }

    func testSlowStrokeAndReturnToOriginDoNotBecomeLongPressOrTap() {
        var stroke = PetContact(point: .zero, time: 1)
        XCTAssertEqual(stroke.move(to: CGPoint(x: 15, y: 0), at: 1.4), .petting)
        XCTAssertEqual(stroke.move(to: .zero, at: 1.8), .petting)
        XCTAssertNil(stroke.hold(at: 2))
        XCTAssertEqual(stroke.end(at: .zero, time: 2.1), .petting)
        var slow = PetContact(point: .zero, time: 1)
        XCTAssertEqual(slow.move(to: CGPoint(x: 80, y: 0), at: 2), .petting)
    }

    @MainActor func testCursorMovesHeadAndPupilsThenSettlesWithoutChangingControls() throws {
        let character = CatSceneController(package: try TestCompanion.package(), animate: false)
        let baseline = CatSceneController(package: try TestCompanion.package(), animate: false)
        let head = try XCTUnwrap(character.joints["head"])
        let pupil = try XCTUnwrap(character.faceRig?.root.childNode(withName: "LeftEye", recursively: false)?
            .childNode(withName: "Pupil", recursively: false))
        character.headYaw = 0.07
        baseline.headYaw = 0.07
        character.followCursor(SIMD2(4, 2))
        for _ in 0..<100 { character.updateFrame(); baseline.updateFrame() }
        XCTAssertGreaterThan(head.simdEulerAngles.y, 0.28)
        XCTAssertLessThan(head.simdEulerAngles.x, -0.14)
        XCTAssertGreaterThan(pupil.simdPosition.x, 0.15)
        XCTAssertGreaterThan(pupil.simdPosition.y, 0.19)
        XCTAssertEqual(character.headYaw, 0.07)
        character.followCursor(nil)
        for _ in 0..<180 { character.updateFrame(); baseline.updateFrame() }
        XCTAssertEqual(head.simdEulerAngles.y, baseline.joints["head"]!.simdEulerAngles.y, accuracy: 0.001)
        XCTAssertEqual(head.simdEulerAngles.x, baseline.joints["head"]!.simdEulerAngles.x, accuracy: 0.001)
        XCTAssertEqual(pupil.simdPosition.x, 0, accuracy: 0.001)
        XCTAssertNil(character.reaction)
    }

    @MainActor func testReactionsRestoreSelectedPoseAndKeepSpeechAndManualOffsets() throws {
        let character = CatSceneController(package: try TestCompanion.package(), animate: false)
        let selected = try TestCompanion.pose("thinking")
        character.setPose(selected)
        character.headTilt = 0.12
        character.setLipFrame(LipFrame(open: 0.65, round: 0.2, closed: 0.1))
        for reaction in [PetReaction.touch, .tap, .petting, .longPress, .swipe(SIMD2(1, 0))] {
            character.react(reaction)
            for _ in 0..<20 { character.updateFrame() }
            XCTAssertEqual(character.reaction, reaction)
            XCTAssertEqual(character.pose, selected)
            XCTAssertEqual(character.headTilt, 0.12)
            XCTAssertGreaterThan(character.mouthRig?.opening ?? 0, 0.6)
            for _ in 0..<240 { character.updateFrame() }
            XCTAssertNil(character.reaction)
            XCTAssertEqual(character.pose, selected)
            XCTAssertEqual(character.faceRig?.expression, selected.expression)
            XCTAssertEqual(character.avatar.simdScale.y, 1, accuracy: 0.001)
            XCTAssertEqual(character.avatar.simdPosition.x, 0, accuracy: 0.001)
        }
    }

    @MainActor func testHeldCuddlePersistsUntilReleaseAndNewPoseCancelsReaction() throws {
        let character = CatSceneController(package: try TestCompanion.package(), animate: false)
        character.setTouching(true)
        character.react(.longPress)
        for _ in 0..<300 { character.updateFrame() }
        XCTAssertEqual(character.reaction, .longPress)
        character.setTouching(false)
        for _ in 0..<180 { character.updateFrame() }
        XCTAssertNil(character.reaction)
        character.react(.tap)
        character.setPose(try TestCompanion.pose("sleepy"))
        character.updateFrame()
        XCTAssertNil(character.reaction)
        XCTAssertEqual(character.faceRig?.expression, "sleepy")
    }

    @MainActor func testCustomPoseIDsStillReactAndEmptyStageIgnoresInteractions() throws {
        let package = try TestCompanion.package()
        let custom = CompanionPackage(root: package.root,
            manifest: CompanionManifest(formatVersion: 1, id: "custom", name: "Custom", rig: "painted-cat-v1",
                models: package.manifest.models, primaryModel: package.manifest.primaryModel,
                personality: package.manifest.personality, poses: package.manifest.poses, defaultPose: "rest"),
            personality: package.personality, poses: [renamed(package.defaultPose, "rest")])
        let character = CatSceneController(package: custom, animate: false)
        character.react(.swipe(SIMD2(-1, 0)))
        for _ in 0..<20 { character.updateFrame() }
        XCTAssertNotNil(character.reaction)
        XCTAssertGreaterThan(abs(character.joints["rightArm"]!.simdEulerAngles.z), 0.1)
        for _ in 0..<240 { character.updateFrame() }
        XCTAssertEqual(character.pose?.id, "rest")
        XCTAssertNil(character.reaction)
        character.react(.swipe(SIMD2(.nan, 0)))
        XCTAssertNil(character.reaction)
        let empty = CatSceneController(animate: false)
        empty.react(.tap)
        empty.updateFrame()
        XCTAssertNil(empty.reaction)
    }

    @MainActor func testStageHitsPetAndRoutesTapWithoutOrbiting() throws {
        let character = CatSceneController(package: try TestCompanion.package(), animate: false)
        let view = PetSceneView(controller: character)
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 600)
        view.scene = character.scene
        view.pointOfView = character.camera
        view.allowsCameraControl = true
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { view.cancelInteraction(); window.contentView = nil }
        _ = view.snapshot()
        let projected = view.projectPoint(SCNVector3(0, 0.15, 0.08))
        let point = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
        XCTAssertTrue(view.isPet(at: point))
        XCTAssertFalse(view.isPet(at: CGPoint(x: 10, y: 10)))
        let time = ProcessInfo.processInfo.systemUptime
        view.mouseDown(with: try mouse(.leftMouseDown, point: point, time: time, window: window))
        XCTAssertEqual(character.reaction, .touch)
        XCTAssertFalse(view.allowsCameraControl)
        view.mouseUp(with: try mouse(.leftMouseUp, point: point, time: time + 0.1, window: window))
        XCTAssertEqual(character.reaction, .tap)
        XCTAssertTrue(view.allowsCameraControl)
        view.cancelInteraction()
        XCTAssertNil(character.reaction)
        view.mouseDown(with: try mouse(.leftMouseDown, point: point, time: time + 1, window: window, modifiers: .option))
        XCTAssertNil(character.reaction)
        XCTAssertTrue(view.allowsCameraControl)
        view.mouseUp(with: try mouse(.leftMouseUp, point: point, time: time + 1.1, window: window, modifiers: .option))
    }

    @MainActor private func mouse(_ type: NSEvent.EventType, point: CGPoint, time: TimeInterval,
        window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
            timestamp: time, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func renamed(_ pose: CatPose, _ id: String) -> CatPose {
        CatPose(id: id, title: pose.title, symbol: pose.symbol, expression: pose.expression,
            criteria: pose.criteria, jointAngles: pose.jointAngles, jointWaves: pose.jointWaves,
            breathingAmplitude: pose.breathingAmplitude, breathingFrequency: pose.breathingFrequency,
            bounceAmplitude: pose.bounceAmplitude, bounceFrequency: pose.bounceFrequency, tail: pose.tail)
    }
}

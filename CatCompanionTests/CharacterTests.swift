import XCTest
import SceneKit
import AppKit
import AVFoundation
import Combine
@testable import CatCompanion

final class CharacterTests: XCTestCase {
    @MainActor func testSkeletonBindsAllOriginalParts() throws {
        let character = CatSceneController(package: try TestCompanion.package(), animate: false)
        XCTAssertNil(character.loadError)
        XCTAssertEqual(character.joints.count, 15)
        XCTAssertEqual(character.meshes.count, 9)
        for (meshName, jointName) in RigJoint.meshJoints {
            let node = try XCTUnwrap(character.meshes[meshName])
            let skinner = try XCTUnwrap(node.skinner)
            XCTAssertEqual(skinner.bones.count, meshName == "Tail" ? 4 : 1)
            XCTAssertEqual(skinner.bones.first?.name, jointName)
            let rest = try XCTUnwrap(RigJoint.skeleton.first { $0.name == jointName })
            let bone = try XCTUnwrap(character.joints[jointName])
            XCTAssertEqual(bone.simdWorldPosition.x, rest.rest.x, accuracy: 0.00001)
            XCTAssertEqual(bone.simdWorldPosition.y, rest.rest.y, accuracy: 0.00001)
            XCTAssertEqual(bone.simdWorldPosition.z, rest.rest.z, accuracy: 0.00001)
            let identity = simd_mul(bone.simdWorldTransform, simd_float4x4(skinner.boneInverseBindTransforms!.first!.scnMatrix4Value))
            XCTAssertEqual(identity.columns.3.x, 0, accuracy: 0.00001)
            XCTAssertEqual(identity.columns.3.y, 0, accuracy: 0.00001)
            XCTAssertEqual(identity.columns.0.x, 1, accuracy: 0.00001)
        }
        let mouth = try XCTUnwrap(character.mouthRig)
        XCTAssertNotNil(mouth.lips.geometry)
        XCTAssertNotNil(mouth.cavity.geometry)
        XCTAssertEqual(mouth.root.parent?.name, "FaceRig")
        XCTAssertEqual(character.faceRig?.root.parent?.name, "head")
        XCTAssertEqual(mouth.opening, 0)
        XCTAssertTrue(mouth.tongue.isHidden)
    }

    @MainActor func testCatRendersWithBoundSkeleton() throws {
        let character = CatSceneController(package: try TestCompanion.package(), animate: false)
        XCTAssertNil(character.loadError)
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = character.scene
        renderer.pointOfView = character.camera
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 900, height: 900), antialiasingMode: .multisampling4X)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cat-companion-scene.png"))
        print("Rendered preview: \(NSTemporaryDirectory())cat-companion-scene.png")
        XCTAssertGreaterThan(png.count, 30_000, "The stage should render the textured cat, not a blank background.")
        let top = try XCTUnwrap(bitmap.colorAt(x: 450, y: 30)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(top.redComponent, 0.97, accuracy: 0.035, "The head must fit inside the stage rather than crop at the top.")
        XCTAssertEqual(top.greenComponent, 0.94, accuracy: 0.035)
        let skin = try XCTUnwrap(bitmap.colorAt(x: 450, y: 420)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(skin.redComponent, 0.80, "The facial surface should have clean fur rather than the old illustrated eye.")
    }

    @MainActor func testEveryExpressionReusesOneHeadAndOneMouth() throws {
        let character = CatSceneController(package: try TestCompanion.package(), animate: false)
        XCTAssertNil(character.loadError)
        let head = try XCTUnwrap(character.meshes["Head"])
        let originalGeometry = try XCTUnwrap(head.geometry)
        XCTAssertEqual(originalGeometry.sources(for: .vertex).first?.vectorCount,
                       originalGeometry.sources(for: .texcoord).first?.vectorCount)
        XCTAssertTrue(originalGeometry.elements.allSatisfy { $0.indicesChannelCount == 1 })
        for pose in try TestCompanion.package().poses {
            character.setPose(pose)
            character.updateFrame()
            XCTAssertTrue(character.meshes["Head"] === head)
            XCTAssertTrue(head.geometry === originalGeometry)
            XCTAssertEqual(head.geometry?.firstMaterial?.name, "UnifiedFace")
            XCTAssertEqual(character.faceRig?.expression, pose.expression)
            var heads = 0, mouths = 0, faces = 0
            character.scene.rootNode.enumerateChildNodes { node, _ in
                if node.name == "Head", node.geometry != nil { heads += 1 }
                if node.name == "MouthRig" { mouths += 1 }
                if node.name == "FaceRig" { faces += 1 }
            }
            XCTAssertEqual(heads, 1)
            XCTAssertEqual(mouths, 1)
            XCTAssertEqual(faces, 1)
        }
    }

    @MainActor func testNewGesturesMoveBothArmsAndResetWhenReturningToIdle() throws {
        let character = CatSceneController(package: try TestCompanion.package(), animate: false)
        let left = try XCTUnwrap(character.joints["leftArm"])
        let right = try XCTUnwrap(character.joints["rightArm"])
        let body = try XCTUnwrap(character.joints["body"])
        for id in ["playful", "cuddle", "shy", "stretch", "thinking", "excited"] {
            character.setPose(try TestCompanion.pose(id))
            for _ in 0..<100 { character.updateFrame() }
            XCTAssertGreaterThan(simd_length(left.simdEulerAngles) + simd_length(right.simdEulerAngles), 0.1)
            for joint in character.joints.values {
                let angles = joint.simdEulerAngles
                XCTAssertTrue(angles.x.isFinite && angles.y.isFinite && angles.z.isFinite)
            }
        }
        character.setPose(try TestCompanion.pose("idle"))
        for _ in 0..<150 { character.updateFrame() }
        XCTAssertLessThan(simd_length(left.simdEulerAngles), 0.001)
        XCTAssertLessThan(simd_length(right.simdEulerAngles), 0.001)
        XCTAssertLessThan(simd_length(body.simdEulerAngles), 0.001)
    }

    @MainActor func testSparklingEyesBlinkWithoutAccumulatingFeatures() throws {
        let character = CatSceneController(package: try TestCompanion.package(), animate: false)
        let face = try XCTUnwrap(character.faceRig)
        face.setExpression("bright")
        let eye = try XCTUnwrap(face.root.childNode(withName: "LeftEye", recursively: false))
        XCTAssertNotNil(eye.childNode(withName: "EyeHighlight", recursively: false))
        XCTAssertNotNil(eye.childNode(withName: "EyeHighlightSmall", recursively: false))
        face.animate(time: 0)
        let open = eye.simdScale.y
        face.animate(time: 4.62)
        XCTAssertLessThan(eye.simdScale.y, open * 0.15)
        face.animate(time: 5)
        XCTAssertEqual(eye.simdScale.y, open, accuracy: 0.0001)
        for value in ["happy", "sleepy", "wink", "surprised", "bright"] {
            face.setExpression(value)
            XCTAssertLessThanOrEqual(eye.childNodes.count, 4)
        }
    }

    @MainActor func testRenderEveryPoseForVisualReview() throws {
        let character = CatSceneController(package: try TestCompanion.package(), animate: false)
        XCTAssertNil(character.loadError)
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = character.scene
        renderer.pointOfView = character.camera
        let tile = CGSize(width: 400, height: 420)
        let sheet = NSImage(size: CGSize(width: tile.width * 4, height: tile.height * 3))
        let poses = try TestCompanion.package().poses
        sheet.lockFocus()
        NSColor(calibratedRed: 0.97, green: 0.94, blue: 0.88, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        for (index, pose) in poses.enumerated() {
            character.setPose(pose)
            for _ in 0..<100 { character.updateFrame() }
            let image = renderer.snapshot(atTime: 0, with: CGSize(width: 400, height: 400), antialiasingMode: .multisampling4X)
            let origin = CGPoint(x: CGFloat(index % 4) * tile.width, y: CGFloat(2 - index / 4) * tile.height)
            image.draw(in: CGRect(x: origin.x, y: origin.y + 20, width: 400, height: 400))
            (pose.title as NSString).draw(at: CGPoint(x: origin.x + 16, y: origin.y + 2), withAttributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.brown
            ])
        }
        sheet.unlockFocus()
        let tiff = try XCTUnwrap(sheet.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cat-companion-poses.png"))
        XCTAssertGreaterThan(png.count, 100_000)
    }

    @MainActor func testMouthOpensClosesAndPreservesTheHead() throws {
        let character = CatSceneController(package: try TestCompanion.package(), animate: false)
        let mouth = try XCTUnwrap(character.mouthRig)
        let head = try XCTUnwrap(character.meshes["Head"]?.geometry)
        let originalBounds = head.boundingBox
        let closedBounds = try XCTUnwrap(mouth.lips.geometry).boundingBox
        mouth.apply(LipFrame(open: 0.85, round: 0.20, closed: 0.15))
        let openBounds = try XCTUnwrap(mouth.lips.geometry).boundingBox
        XCTAssertGreaterThan(mouth.opening, 0.8)
        XCTAssertFalse(mouth.tongue.isHidden)
        XCTAssertLessThan(openBounds.min.y, closedBounds.min.y - 0.008)
        XCTAssertEqual(head.boundingBox.min.y, originalBounds.min.y)
        mouth.apply(.silence)
        XCTAssertEqual(mouth.opening, 0)
        XCTAssertTrue(mouth.tongue.isHidden)
        XCTAssertEqual(mouth.lips.geometry!.boundingBox.min.y, closedBounds.min.y, accuracy: 0.00001)
    }

    @MainActor func testTailIsWeightedAndItsHipStaysFixedDuringSwing() throws {
        let character = CatSceneController(package: try TestCompanion.package(), animate: false)
        let tail = try XCTUnwrap(character.meshes["Tail"]?.skinner)
        XCTAssertEqual(tail.bones.map(\.name), CatTailGeometry.boneNames.map { Optional($0) })
        XCTAssertEqual(tail.boneWeights.componentsPerVector, 4)
        let hip = try XCTUnwrap(character.joints["tail"])
        let rest = hip.simdPosition
        let tip = try XCTUnwrap(character.joints["tailTip"])
        let initialTip = character.avatar.convertPosition(SCNVector3Zero, from: tip)
        character.tailSwing = 0.5
        for _ in 0..<120 { character.updateFrame() }
        XCTAssertEqual(hip.simdPosition, rest)
        XCTAssertEqual(hip.simdEulerAngles, SIMD3<Float>.zero)
        let movedTip = character.avatar.convertPosition(SCNVector3Zero, from: tip)
        XCTAssertGreaterThan(simd_distance(SIMD3<Float>(initialTip), SIMD3<Float>(movedTip)), 0.002)
        let anchor = CatTailGeometry.center(at: 0)
        let body = try XCTUnwrap(character.meshes["Body"]?.geometry).boundingBox
        XCTAssertGreaterThan(anchor.x, Float(body.min.x))
        XCTAssertLessThan(anchor.x, Float(body.max.x))
        XCTAssertGreaterThan(anchor.y, Float(body.min.y))
        XCTAssertLessThan(anchor.y, Float(body.max.y))
    }

    func testPlaybackEnvelopePreservesSyllablesInLargeBuffers() {
        let quiet = [Float](repeating: 0, count: 480)
        let speech: [Float] = (0..<480).map { index in
            let phase = Double(index) * 2 * Double.pi * 200 / 24000
            return Float(sin(phase)) * 0.12
        }
        let samples = quiet + speech + quiet
        let envelope = PlaybackLipEnvelope.frames(samples: samples, sampleRate: 24000)
        XCTAssertEqual(envelope.count, 6)
        XCTAssertEqual(envelope[0].frame, LipFrame.silence)
        XCTAssertEqual(envelope[1].frame, LipFrame.silence)
        XCTAssertGreaterThan(envelope[2].frame.open, 0.5)
        XCTAssertGreaterThan(envelope[3].frame.open, 0.5)
        XCTAssertEqual(envelope[4].frame, LipFrame.silence)
        XCTAssertEqual(envelope[5].offset, 0.05, accuracy: 0.00001)
    }

    func testIdleTailHasBoundedSwayAndNonRepeatingTipFlicks() throws {
        let idle = try TestCompanion.pose("idle")
        let samples = (0..<2400).map { i in
            CatTailMotion.targets(motion: idle.tail, time: Float(i) / 60, moodElapsed: Float(i) / 60, manualSwing: 0)
        }
        let yaw = samples.map { $0[2].y }
        XCTAssertGreaterThan(yaw.max()! - yaw.min()!, 0.10)
        for index in 1..<samples.count {
            XCTAssertLessThan(simd_distance(samples[index][2], samples[index - 1][2]), 0.04)
        }
        let first = CatTailMotion.targets(motion: idle.tail, time: 3, moodElapsed: 3, manualSwing: 0)[2]
        let later = CatTailMotion.targets(motion: idle.tail, time: 10.3, moodElapsed: 10.3, manualSwing: 0)[2]
        XCTAssertGreaterThan(simd_distance(first, later), 0.005, "Idle should not replay an identical fixed sway cycle.")
    }

    func testTailMoodChangesActivityAndSurpriseSettles() throws {
        func activity(_ id: String) throws -> Float {
            let mood = try TestCompanion.pose(id)
            let values = (0..<600).map { CatTailMotion.targets(motion: mood.tail, time: Float($0) / 60, moodElapsed: 10, manualSwing: 0)[2] }
            return (1..<values.count).reduce(Float(0)) { $0 + simd_distance(values[$1], values[$1 - 1]) }
        }
        XCTAssertGreaterThan(try activity("happy"), try activity("sleepy") * 10)
        XCTAssertGreaterThan(try activity("wave"), try activity("idle"))
        let alert = CatTailMotion.targets(motion: try TestCompanion.pose("surprised").tail, time: 0.3, moodElapsed: 0.1, manualSwing: 0)[2]
        let settled = CatTailMotion.targets(motion: try TestCompanion.pose("surprised").tail, time: 0.3, moodElapsed: 8, manualSwing: 0)[2]
        XCTAssertGreaterThan(abs(alert.y), abs(settled.y) * 3)
        for mood in try TestCompanion.package().poses {
            for value in CatTailMotion.targets(motion: mood.tail, time: 3, moodElapsed: 0, manualSwing: 0.5) {
                XCTAssertTrue(value.x.isFinite && value.y.isFinite && value.z.isFinite)
                XCTAssertLessThanOrEqual(abs(value.y), 0.45)
            }
        }
    }

    @MainActor func testRenderedAudioDrivesTheLipTimeline() async throws {
        // Mute the output mixer; the player tap still renders real audio samples.
        let audio = AudioController(outputVolume: 0)
        let moved = expectation(description: "Rendered speech energy drives lips")
        var fulfilled = false
        audio.onLipFrame = { frame in
            if frame.open > 0.4, !fulfilled { fulfilled = true; moved.fulfill() }
        }
        let samples: [Int16] = (0..<24000).map { index in
            Int16(sin(Double(index) * 2 * Double.pi * 200 / 24000) * 5000)
        }
        let data = samples.withUnsafeBytes { Data($0) }
        try audio.playPCM(data)
        await fulfillment(of: [moved], timeout: 3)
        audio.stopPlayback()
        XCTAssertFalse(audio.isSpeaking)
    }

    @MainActor func testMicrophoneStaysPausedAcrossStreamGapsAndUntilPlaybackDrains() async throws {
        let audio = AudioController(outputVolume: 0)
        defer { audio.stopCapture(); audio.stopPlayback() }
        audio.beginResponse()
        XCTAssertTrue(audio.isListeningPaused)

        // Enabling the microphone during a reply must defer capture. Muting it
        // afterward must prevent automatic resumption from overriding the user.
        try audio.startCapture()
        XCTAssertTrue(audio.isMicrophoneEnabled)
        XCTAssertFalse(audio.isCapturing)
        audio.stopCapture()

        let shortChunk = [Int16](repeating: 4000, count: 2400).withUnsafeBytes { Data($0) }
        let firstDrained = expectation(description: "First streamed chunk rendered")
        let firstObserver = audio.$isSpeaking.dropFirst().filter { !$0 }.prefix(1).sink { _ in firstDrained.fulfill() }
        try audio.playPCM(shortChunk)
        await fulfillment(of: [firstDrained], timeout: 3)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(audio.isSpeaking)
        XCTAssertTrue(audio.isListeningPaused, "A gap between chunks must not reopen the microphone")
        firstObserver.cancel()

        let longChunk = [Int16](repeating: 4000, count: 24000).withUnsafeBytes { Data($0) }
        let playbackDrained = expectation(description: "Final chunk rendered")
        let listeningResumed = expectation(description: "Listening pause cleared after playback")
        let playbackObserver = audio.$isSpeaking.dropFirst().filter { !$0 }.prefix(1).sink { _ in playbackDrained.fulfill() }
        let listeningObserver = audio.$isListeningPaused.dropFirst().filter { !$0 }.prefix(1).sink { _ in listeningResumed.fulfill() }
        audio.beginResponse()
        try audio.playPCM(longChunk)
        audio.finishResponse()
        XCTAssertTrue(audio.isSpeaking)
        XCTAssertTrue(audio.isListeningPaused, "The server finishing must not reopen input while audio is queued")
        await fulfillment(of: [playbackDrained], timeout: 3)
        XCTAssertTrue(audio.isListeningPaused, "The microphone must also stay paused during the echo-decay delay")
        await fulfillment(of: [listeningResumed], timeout: 2)
        XCTAssertFalse(audio.isCapturing)
        XCTAssertFalse(audio.isMicrophoneEnabled, "Manual mute must survive playback completion")
        playbackObserver.cancel(); listeningObserver.cancel()
    }

    @MainActor func testNewResponseCancelsPendingMicrophoneResumption() async throws {
        let audio = AudioController(outputVolume: 0)
        defer { audio.stopCapture(); audio.stopPlayback() }
        audio.beginResponse()
        audio.finishResponse()
        try await Task.sleep(for: .milliseconds(100))
        audio.beginResponse()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(audio.isListeningPaused)
        XCTAssertFalse(audio.isCapturing)

        let released = expectation(description: "Stopped playback releases the pause")
        let observer = audio.$isListeningPaused.dropFirst().filter { !$0 }.prefix(1).sink { _ in released.fulfill() }
        audio.stopCapture()
        audio.stopPlayback()
        await fulfillment(of: [released], timeout: 2)
        XCTAssertFalse(audio.isMicrophoneEnabled)
        observer.cancel()
    }

    func testPCM16IsLittleEndian() {
        let samples = PCM16.decode(Data([0, 0, 0xff, 0x7f, 0, 0x80, 0xff]))
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples[0], 0)
        XCTAssertEqual(samples[1], Float(32767) / 32768)
        XCTAssertEqual(samples[2], -1)
    }

    func testLipSyncSilenceAndSpeechEnergy() {
        XCTAssertEqual(LipSyncAnalyzer.analyze([]), .silence)
        XCTAssertEqual(LipSyncAnalyzer.analyze([Float](repeating: 0, count: 480)), .silence)
        let voiced = (0..<480).map { Float(sin(Double($0) * 2 * .pi * 200 / 24000)) * 0.12 }
        let frame = LipSyncAnalyzer.analyze(voiced)
        XCTAssertGreaterThan(frame.open, 0.5)
        XCTAssertGreaterThan(frame.round, 0.1)
        XCTAssertLessThan(frame.closed, LipFrame.silence.closed)
        let smoothed = LipFrame.silence.blended(toward: frame, amount: 0.35)
        XCTAssertGreaterThan(smoothed.open, 0)
        XCTAssertLessThan(smoothed.open, frame.open)
    }
}

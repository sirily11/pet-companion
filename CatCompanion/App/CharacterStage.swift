import AppKit
import SceneKit
import SwiftUI

struct CharacterStage: NSViewRepresentable {
    let controller: CatSceneController
    func makeNSView(context: Context) -> PetSceneView {
        let view = PetSceneView(controller: controller)
        view.scene = controller.scene
        view.pointOfView = controller.camera
        view.backgroundColor = .clear
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.isPlaying = true
        view.defaultCameraController.target = SCNVector3(-0.01, 0.135, 0)
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.minimumVerticalAngle = -20
        view.defaultCameraController.maximumVerticalAngle = 40
        view.setAccessibilityLabel(controller.package?.manifest.name ?? "Pet companion")
        view.setAccessibilityHelp("Move the pointer to catch their eye. Tap, stroke, swipe, or hold on your pet. Drag the background or Option-drag to orbit.")
        return view
    }
    func updateNSView(_ view: PetSceneView, context: Context) {
        // Reassigning the point of view on every state update would reset orbiting.
    }

    static func dismantleNSView(_ view: PetSceneView, coordinator: ()) {
        view.cancelInteraction()
    }
}

/// Pet contacts consume their events; background gestures keep SceneKit's camera controls.
@MainActor
final class PetSceneView: SCNView {
    let controller: CatSceneController
    private var pointerTracking: NSTrackingArea?
    private var contact: PetContact?
    private var holdTimer: Timer?
    private var windowObserver: NSObjectProtocol?
    private var cameraWasEnabled = true
    private var scrollContact = false
    private var scrollTravel = SIMD2<Float>.zero
    private var scrollRecognized = false
    private var lastScrollTime: TimeInterval = 0

    init(controller: CatSceneController) {
        self.controller = controller
        super.init(frame: .zero, options: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(controller:)") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        pointerTracking = tracking
        addTrackingArea(tracking)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        cancelInteraction()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        if let newWindow {
            windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: newWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelInteraction() }
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    deinit {
        holdTimer?.invalidate()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }

    override func mouseEntered(with event: NSEvent) { followPointer(event) }
    override func mouseMoved(with event: NSEvent) { followPointer(event) }
    override func mouseExited(with event: NSEvent) { controller.followCursor(nil) }

    private func followPointer(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), let head = controller.joints["head"], let pointOfView else {
            controller.followCursor(nil)
            return
        }
        let center = projectPoint(head.presentation.worldPosition)
        let x = max(-1, min(1, Float(point.x - CGFloat(center.x)) / Float(max(1, bounds.width * 0.35))))
        let y = max(-1, min(1, Float(point.y - CGFloat(center.y)) / Float(max(1, bounds.height * 0.35))))
        let direction = head.parent!.presentation.convertVector(SCNVector3(x, y, 0), from: pointOfView.presentation)
        controller.followCursor(SIMD2(Float(direction.x), Float(direction.y)))
    }

    func isPet(at point: CGPoint) -> Bool {
        hitTest(point, options: [.rootNode: controller.avatar, .ignoreHiddenNodes: true, .searchMode: SCNHitTestSearchMode.all.rawValue])
            .contains { hit in
                var node: SCNNode? = hit.node
                while let current = node, current !== controller.avatar {
                    if current.name == "FaceRig" || controller.meshes.values.contains(where: { $0 === current }) { return true }
                    node = current.parent
                }
                return false
            }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !event.modifierFlags.contains(.option), isPet(at: point) else {
            controller.followCursor(nil)
            super.mouseDown(with: event)
            return
        }
        cameraWasEnabled = allowsCameraControl
        allowsCameraControl = false
        contact = PetContact(point: point, time: event.timestamp)
        controller.setTouching(true)
        controller.react(.touch)
        followPointer(event)
        let timer = Timer(timeInterval: PetContact.longPressDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let reaction = self.contact?.hold(at: ProcessInfo.processInfo.systemUptime) { self.controller.react(reaction) }
            }
        }
        holdTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func mouseDragged(with event: NSEvent) {
        guard contact != nil else { super.mouseDragged(with: event); return }
        followPointer(event)
        if let reaction = contact?.move(to: convert(event.locationInWindow, from: nil), at: event.timestamp) {
            controller.react(reaction)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard contact != nil else { super.mouseUp(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        let reaction = contact?.end(at: point, time: event.timestamp)
        finishContact()
        if bounds.contains(point), let reaction { controller.react(reaction) }
        followPointer(event)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !event.hasPreciseScrollingDeltas || event.modifierFlags.contains(.option) {
            super.scrollWheel(with: event)
            return
        }
        if event.phase.contains(.began) || (event.phase.isEmpty && event.momentumPhase.isEmpty && event.timestamp - lastScrollTime > 0.25) {
            scrollContact = isPet(at: point)
            scrollTravel = .zero
            scrollRecognized = false
        }
        lastScrollTime = event.timestamp
        guard scrollContact else { super.scrollWheel(with: event); return }
        // Momentum belongs to the same swipe and must not start another reaction.
        guard event.momentumPhase.isEmpty else { return }
        scrollTravel += SIMD2(Float(event.scrollingDeltaX), Float(event.scrollingDeltaY))
        if !scrollRecognized, simd_length(scrollTravel) >= 24 {
            scrollRecognized = true
            controller.react(.swipe(simd_normalize(scrollTravel)))
        }
        if event.phase.contains(.cancelled) { scrollContact = false }
    }

    override func swipe(with event: NSEvent) {
        let direction = SIMD2(Float(event.deltaX), Float(event.deltaY))
        guard isPet(at: convert(event.locationInWindow, from: nil)), simd_length(direction) > 0 else {
            super.swipe(with: event)
            return
        }
        controller.react(.swipe(simd_normalize(direction)))
    }

    private func finishContact() {
        holdTimer?.invalidate(); holdTimer = nil
        contact = nil
        controller.setTouching(false)
        allowsCameraControl = cameraWasEnabled
    }

    func cancelInteraction() {
        if contact != nil { finishContact() }
        scrollContact = false; scrollTravel = .zero; scrollRecognized = false
        controller.clearInteraction()
    }
}

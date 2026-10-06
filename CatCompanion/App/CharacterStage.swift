import AppKit
import SceneKit
import SwiftUI

struct PetReactionStatus: View {
    @ObservedObject var character: CatSceneController
    let onSettings: () -> Void

    var body: some View {
        if let error = character.interactionError {
            VStack(spacing: 6) {
                Text(error).font(.system(size: 11)).multilineTextAlignment(.center)
                Button(action: onSettings) { Label("Settings", systemImage: "gearshape") }
                    .font(.system(size: 11)).buttonStyle(.plain)
            }
            .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        } else if character.isChoosingReaction {
            Label("Thinking…", systemImage: "sparkles")
                .font(.system(size: 11)).padding(8).background(.regularMaterial, in: Capsule())
                .allowsHitTesting(false)
        }
    }
}

struct CharacterStage: NSViewRepresentable {
    let controller: CatSceneController
    var isDesktopPet = false
    func makeNSView(context: Context) -> PetSceneView {
        let view = PetSceneView(controller: controller, isDesktopPet: isDesktopPet)
        view.scene = controller.scene
        view.pointOfView = controller.camera
        view.backgroundColor = .clear
        view.allowsCameraControl = !isDesktopPet
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.isPlaying = true
        view.defaultCameraController.target = SCNVector3(-0.01, 0.135, 0)
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.minimumVerticalAngle = -20
        view.defaultCameraController.maximumVerticalAngle = 40
        view.setAccessibilityLabel(controller.package?.manifest.name ?? "Pet companion")
        view.setAccessibilityHelp(isDesktopPet
            ? "Tap, stroke, swipe, or hold on your pet. Option-drag to move them around your desktop."
            : "Move the pointer to catch their eye. Tap, stroke, swipe, or hold on your pet. Drag the background or Option-drag to orbit.")
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
    let isDesktopPet: Bool
    var hasActiveContact: Bool { contact != nil }
    private var pointerTracking: NSTrackingArea?
    private var contact: PetContact?
    private var lastContactInteraction: PetReaction?
    private var holdTimer: Timer?
    private var windowObserver: NSObjectProtocol?
    private var cameraWasEnabled = true
    private var scrollContact = false
    private var scrollTravel = SIMD2<Float>.zero
    private var scrollRecognized = false
    private var lastScrollTime: TimeInterval = 0

    init(controller: CatSceneController, isDesktopPet: Bool = false) {
        self.controller = controller
        self.isDesktopPet = isDesktopPet
        super.init(frame: .zero, options: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(controller:)") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let activity: NSTrackingArea.Options = isDesktopPet ? .activeAlways : .activeInKeyWindow
        let tracking = NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, activity, .inVisibleRect], owner: self, userInfo: nil)
        pointerTracking = tracking
        addTrackingArea(tracking)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil { cancelInteraction() }
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
        if isDesktopPet, event.modifierFlags.contains(.option) || !isPet(at: point) {
            cancelInteraction()
            (window as? DesktopPetPanel)?.drag(with: event)
            return
        }
        guard !event.modifierFlags.contains(.option), isPet(at: point) else {
            controller.followCursor(nil)
            super.mouseDown(with: event)
            return
        }
        cameraWasEnabled = allowsCameraControl
        allowsCameraControl = false
        contact = PetContact(point: point, time: event.timestamp)
        lastContactInteraction = nil
        controller.beginContact()
        followPointer(event)
        let timer = Timer(timeInterval: PetContact.longPressDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let reaction = self.contact?.hold(at: ProcessInfo.processInfo.systemUptime) { self.submitContact(reaction) }
            }
        }
        holdTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func mouseDragged(with event: NSEvent) {
        guard contact != nil else { super.mouseDragged(with: event); return }
        followPointer(event)
        if let reaction = contact?.move(to: convert(event.locationInWindow, from: nil), at: event.timestamp) {
            submitContact(reaction)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard contact != nil else { super.mouseUp(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        let reaction = contact?.end(at: point, time: event.timestamp)
        if bounds.contains(point), let reaction { submitContact(reaction) }
        finishContact()
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
            controller.interact(.swipe(simd_normalize(scrollTravel)))
        }
        if event.phase.contains(.cancelled) { scrollContact = false }
    }

    override func swipe(with event: NSEvent) {
        let direction = SIMD2(Float(event.deltaX), Float(event.deltaY))
        guard isPet(at: convert(event.locationInWindow, from: nil)), simd_length(direction) > 0 else {
            super.swipe(with: event)
            return
        }
        controller.interact(.swipe(simd_normalize(direction)))
    }

    private func submitContact(_ gesture: PetReaction) {
        // Movement samples and mouse-up belong to the same stroke/cuddle.
        guard gesture != lastContactInteraction else { return }
        lastContactInteraction = gesture
        controller.interact(gesture)
    }

    private func finishContact() {
        holdTimer?.invalidate(); holdTimer = nil
        contact = nil
        lastContactInteraction = nil
        controller.setTouching(false)
        allowsCameraControl = cameraWasEnabled
    }

    func cancelInteraction() {
        if contact != nil { finishContact() }
        scrollContact = false; scrollTravel = .zero; scrollRecognized = false
        controller.clearInteraction()
    }
}

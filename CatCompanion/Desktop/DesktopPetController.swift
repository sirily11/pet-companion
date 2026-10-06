import AppKit
import Combine
import SwiftUI

@MainActor
final class DesktopPetController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isVisible = false
    @Published private(set) var error: String?
    let behavior = DesktopPetBehavior()
    let voice: DesktopPetVoiceState
    var onHide: (() -> Void)?
    var onShowCharacter: ((CatSceneController) -> Void)?
    private(set) var panel: DesktopPetPanel?
    private var pointerTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var lastOrigin: CGPoint?
    static let windowSize = CGSize(width: 320, height: 414)

    init(voice: DesktopPetVoiceState) {
        self.voice = voice
        super.init()
    }

    func clearError() { error = nil }

    func show(package: CompanionPackage) {
        let character = CatSceneController(package: package, stage: .desktop)
        guard character.loadError == nil else { error = character.loadError; return }
        hide()
        error = nil
        let panel = DesktopPetPanel(contentRect: CGRect(origin: .zero, size: Self.windowSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "\(package.manifest.name) — Desktop Pet"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: DesktopPetView(behavior: behavior, voice: voice,
            onHide: { [weak self] in self?.hide() }))
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let origin = lastOrigin ?? CGPoint(x: visible.maxX - Self.windowSize.width - 24, y: visible.minY + 20)
        panel.setFrame(Self.constrainedFrame(origin: origin, screens: NSScreen.screens.map(\.visibleFrame)), display: false)
        self.panel = panel
        onShowCharacter?(character)
        behavior.start(character: character)
        isVisible = true
        panel.orderFrontRegardless()
        // Transparent space must let clicks reach the app underneath. Sampling the pointer
        // also works while the panel ignores events, without accessibility or input monitoring.
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointerPassthrough() }
        }
        pointerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keepOnScreen() }
            }
    }

    func hide() {
        let wasVisible = isVisible
        pointerTimer?.invalidate(); pointerTimer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        behavior.stop()
        if let panel {
            lastOrigin = panel.frame.origin
            panel.delegate = nil
            panel.close()
        }
        panel = nil
        isVisible = false
        if wasVisible { onHide?() }
    }

    func windowWillClose(_ notification: Notification) { hide() }
    func windowDidMove(_ notification: Notification) { keepOnScreen() }

    private func keepOnScreen() {
        guard let panel, !panel.isDraggingPet else { return }
        let frame = Self.constrainedFrame(origin: panel.frame.origin, screens: NSScreen.screens.map(\.visibleFrame))
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        lastOrigin = frame.origin
    }

    static func constrainedFrame(origin: CGPoint, screens: [CGRect]) -> CGRect {
        let frame = CGRect(origin: origin, size: windowSize)
        guard let screen = screens.max(by: {
            let left = frame.intersection($0), right = frame.intersection($1)
            return (left.isNull ? 0 : left.width * left.height) < (right.isNull ? 0 : right.width * right.height)
        }) else { return frame }
        return CGRect(x: min(max(origin.x, screen.minX), max(screen.minX, screen.maxX - windowSize.width)),
                      y: min(max(origin.y, screen.minY), max(screen.minY, screen.maxY - windowSize.height)),
                      width: windowSize.width, height: windowSize.height)
    }

    private func updatePointerPassthrough() {
        guard let panel, let content = panel.contentView else { return }
        if panel.isDraggingPet { return }
        let point = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        var interactive = false
        func visit(_ view: NSView) {
            guard !view.isHiddenOrHasHiddenAncestor else { return }
            if let stage = view as? PetSceneView {
                let local = stage.convert(point, from: nil)
                if stage.hasActiveContact || (stage.bounds.contains(local) && stage.isPet(at: local)) { interactive = true }
            } else if view is DesktopPetHitRegionView || view is DesktopPetDragView {
                if view.bounds.contains(view.convert(point, from: nil)) { interactive = true }
            }
            for child in view.subviews { visit(child) }
        }
        visit(content)
        panel.ignoresMouseEvents = !interactive
        if !interactive { behavior.character?.followCursor(nil) }
    }
}

@MainActor
final class DesktopPetVoiceState: ObservableObject {
    let live: LiveClient
    let audio: AudioController
    @Published var isRequestingMicrophone = false
    @Published var outputLevel: Float = 0
    @Published var reply: String?
    @Published var hasAttemptedConversation = false
    @Published var needsSettings = false
    @Published var isEditorVisible = false
    var onToggleConversation: (() -> Void)?
    var onToggleMicrophone: (() -> Void)?
    var onShowSettings: (() -> Void)?

    init(live: LiveClient, audio: AudioController) {
        self.live = live
        self.audio = audio
    }
}

final class DesktopPetPanel: NSPanel {
    private(set) var isDraggingPet = false
    private var dragAnchor: (pointer: CGPoint, origin: CGPoint)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func drag(with event: NSEvent) {
        beginDragging(at: convertPoint(toScreen: event.locationInWindow))
        performDrag(with: event)
        finishDragging()
    }

    func beginDragging(at pointer: CGPoint) {
        dragAnchor = (pointer, frame.origin)
        isDraggingPet = true
        ignoresMouseEvents = false
    }

    func continueDragging(to pointer: CGPoint) {
        guard let anchor = dragAnchor else { return }
        setFrameOrigin(CGPoint(x: anchor.origin.x + pointer.x - anchor.pointer.x,
                               y: anchor.origin.y + pointer.y - anchor.pointer.y))
    }

    func finishDragging() {
        guard isDraggingPet else { return }
        dragAnchor = nil
        isDraggingPet = false
        delegate?.windowDidMove?(Notification(name: NSWindow.didMoveNotification, object: self))
    }
}

import AppKit
import SwiftUI

@MainActor
struct DesktopPetView: View {
    @ObservedObject var behavior: DesktopPetBehavior
    @ObservedObject var voice: DesktopPetVoiceState
    @ObservedObject private var live: LiveClient
    @ObservedObject private var audio: AudioController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onHide: () -> Void

    init(behavior: DesktopPetBehavior, voice: DesktopPetVoiceState, onHide: @escaping () -> Void) {
        self.behavior = behavior
        self.voice = voice
        self.live = voice.live
        self.audio = voice.audio
        self.onHide = onHide
    }

    private var isConversationStarted: Bool { voice.isRequestingMicrophone || live.state != .disconnected }
    private var conversationError: String? {
        voice.hasAttemptedConversation && live.state == .disconnected ? live.error : nil
    }
    private var bubbleText: String? {
        if let error = conversationError { return error }
        if voice.isRequestingMicrophone { return "Getting ready to listen…" }
        if live.state == .connecting { return "Connecting to Gemini Live…" }
        if live.state == .connected {
            if let reply = voice.reply, !reply.isEmpty { return reply }
            return audio.isMicrophoneEnabled ? "I’m listening. Say hello!" : "Microphone muted."
        }
        return behavior.speech
    }
    private var conversationButtonTitle: String {
        if voice.isRequestingMicrophone || live.state == .connecting { return "Cancel connection" }
        return live.state == .connected ? "End Gemini Live conversation" : "Talk with Gemini Live"
    }
    private static let accent = Color(red: 0.76, green: 0.36, blue: 0.20)
    private var voiceControlTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .scale(scale: 0.3, anchor: .leading).combined(with: .opacity)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if let speech = bubbleText {
                    VStack(spacing: 6) {
                            AutoScrollingText(text: speech, visibleLines: conversationError == nil ? 4 : 3)
                            if conversationError != nil {
                                HStack(spacing: 16) {
                                    Button(action: showSettings) { Label("Settings", systemImage: "gearshape") }
                                    Button {
                                        live.error = nil
                                        voice.hasAttemptedConversation = false
                                    } label: { Image(systemName: "xmark") }
                                    .accessibilityLabel("Dismiss conversation error")
                                }
                                .font(.system(size: 11)).buttonStyle(.plain)
                            }
                    }
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 12)
                    .frame(maxWidth: .infinity)
                    .petGlass(tint: Color(red: 1, green: 0.98, blue: 0.94).opacity(0.55), cornerRadius: 18)
                    .background(DesktopPetHitRegion())
                    .foregroundStyle(Color(red: 0.29, green: 0.22, blue: 0.18))
                    .padding(.horizontal, 20).padding(.top, 6)
                    .accessibilityElement(children: .combine)
                    .transition(.opacity)
                }
            }
            .frame(height: 118)

            if let character = behavior.character {
                CharacterStage(controller: character, isDesktopPet: true)
                    .id(ObjectIdentifier(character))
                    .frame(height: 260)
                    .accessibilityAction(named: "Tap your pet") { character.interact(.tap) }
                    .accessibilityAction(named: "Pet gently") { character.interact(.petting) }
                    .accessibilityAction(named: "Cuddle your pet") { character.interact(.longPress) }
                    .accessibilityAction(named: "Play with your pet") { character.interact(.swipe(SIMD2(1, 0))) }
                    .accessibilityAction(named: "New mood") { behavior.requestMood() }
                    .overlay {
                        DesktopPetFloatingToolCalls(calls: live.visibleToolCalls)
                    }
                    .overlay(alignment: .bottom) {
                        PetReactionStatus(character: character, onSettings: showSettings)
                            .padding(.horizontal, 16)
                            .background(DesktopPetHitRegion())
                    }
                    .accessibilityAction(named: "Talk with Gemini Live") { voice.onToggleConversation?() }
                    .accessibilityAction(named: "Hide desktop pet", onHide)
            }

            HStack(spacing: 6) {
                DesktopPetDragHandle(name: behavior.character?.package?.manifest.name ?? "Your pet")
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .petGlass()
                Button { voice.onToggleConversation?() } label: {
                    if isConversationStarted {
                        Image(systemName: "stop.fill").transition(voiceControlTransition)
                    } else {
                        Label("Talk", systemImage: "mic.fill").transition(voiceControlTransition)
                    }
                }
                .help(conversationButtonTitle).accessibilityLabel(conversationButtonTitle)
                .foregroundStyle(isConversationStarted ? Self.accent : .primary)
                .petGlassButton()
                if voice.isRequestingMicrophone || live.state == .connecting {
                    ProgressView().controlSize(.mini)
                        .frame(width: 30, height: 30)
                        .petGlass()
                        .transition(.opacity)
                } else if live.state == .connected {
                    HStack(spacing: 8) {
                        DesktopVoiceWaveform(level: audio.isSpeaking ? voice.outputLevel : audio.microphoneLevel,
                            isActive: audio.isSpeaking || (audio.isCapturing && !audio.isListeningPaused))
                            .frame(width: 32, height: 18)
                            .help(audio.isSpeaking ? "Pet speaking" : audio.isMicrophoneEnabled ? "Listening" : "Microphone muted")
                        Button { voice.onToggleMicrophone?() } label: {
                            Image(systemName: audio.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill")
                                .contentTransition(.symbolEffect(.replace))
                                .symbolEffect(.pulse, options: .repeating,
                                              isActive: !reduceMotion && audio.isMicrophoneEnabled && audio.isCapturing
                                                  && !audio.isListeningPaused && !audio.isSpeaking)
                        }
                        .buttonStyle(.plain)
                        .help(audio.isMicrophoneEnabled ? "Mute microphone" : "Unmute microphone")
                        .accessibilityLabel(audio.isMicrophoneEnabled ? "Mute microphone" : "Unmute microphone")
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .petGlass(tint: Self.accent.opacity(0.15))
                    .transition(voiceControlTransition)
                }
                Button { behavior.requestMood() } label: { Image(systemName: "sparkles") }
                    .help("Let your pet choose a new mood").accessibilityLabel("New pet mood")
                    .disabled(behavior.isThinking || isConversationStarted || audio.isSpeaking)
                    .petGlassButton()
                Button(action: onHide) { Image(systemName: "xmark") }
                    .help("Hide desktop pet").accessibilityLabel("Hide desktop pet")
                    .petGlassButton()
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.75),
                       value: live.state)
            .animation(.easeInOut(duration: 0.2), value: voice.isRequestingMicrophone)
            .animation(.easeInOut(duration: 0.2), value: audio.isMicrophoneEnabled)
            .background(DesktopPetHitRegion())
            .padding(.horizontal, 16)
            .frame(height: 36)
        }
        .frame(width: DesktopPetController.windowSize.width, height: DesktopPetController.windowSize.height)
        .preferredColorScheme(.light)
        .onChange(of: voice.needsSettings) { _, needsSettings in
            if needsSettings {
                showSettings()
                voice.needsSettings = false
            }
        }
    }

    private func showSettings() {
        if !voice.isEditorVisible { openWindow(id: "editor") }
        NSApp.activate(ignoringOtherApps: true)
        voice.onShowSettings?()
    }
}

private struct DesktopPetFloatingToolCalls: View {
    let calls: [ConversationToolCall]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()

    private var bubbleTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: 0.55).combined(with: .opacity).combined(with: .offset(y: 10)),
            removal: .scale(scale: 0.65).combined(with: .opacity).combined(with: .offset(y: -10)))
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || calls.isEmpty)) { timeline in
                let elapsed = reduceMotion ? 0 : timeline.date.timeIntervalSince(startedAt)
                ZStack {
                    ForEach(calls, id: \.callID) { call in
                        DesktopPetToolCallBubble(call: call)
                            .transition(bubbleTransition)
                            .position(position(for: call, in: geometry.size, elapsed: elapsed))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.8),
                           value: calls.map(\.callID))
            }
        }
    }

    private func position(for call: ConversationToolCall, in size: CGSize, elapsed: TimeInterval) -> CGPoint {
        // A stable phase gives each call its own starting point without jumping on status updates.
        let seed = call.callID.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        let phase = Double(seed % 360) * .pi / 180
        let angle = phase + elapsed * 0.22
        let radiusX = max(0, (size.width - DesktopPetToolCallBubble.diameter) / 2 - 12)
        let radiusY = max(0, (size.height - DesktopPetToolCallBubble.diameter) / 2 - 12)
        let bob = reduceMotion ? 0 : sin(elapsed * 1.3 + phase) * 3
        return CGPoint(x: size.width / 2 + CGFloat(cos(angle)) * radiusX,
                       y: size.height / 2 + CGFloat(sin(angle)) * radiusY + CGFloat(bob))
    }
}

private struct DesktopPetToolCallBubble: View {
    static let diameter: CGFloat = 60
    let call: ConversationToolCall
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var statusColor: Color {
        switch call.status {
        case .running: .blue
        case .completed: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }

    private var statusLabel: String {
        switch call.status {
        case .running: "Calling"
        case .completed: "Done"
        case .failed: "Error"
        case .cancelled: "Cancelled"
        }
    }

    var body: some View {
        Text(call.name.replacingOccurrences(of: "_", with: "\n"))
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.7)
            .frame(width: Self.diameter - 16, height: Self.diameter - 16)
            .frame(width: Self.diameter, height: Self.diameter)
            .foregroundStyle(Color(red: 0.29, green: 0.22, blue: 0.18))
            .petGlass(tint: statusColor.opacity(0.18))
            .overlay(Circle().stroke(statusColor.opacity(0.4), lineWidth: 1.5))
            .overlay(alignment: .topTrailing) {
                statusIndicator.offset(x: 2, y: -2)
            }
            .background(DesktopPetHitRegion())
            .animation(.easeInOut(duration: 0.2), value: call.status)
            .help("\(call.name) · \(statusLabel)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tool: \(call.name), \(statusLabel)")
    }

    private var statusIndicator: some View {
        ZStack {
            if call.status == .running {
                if reduceMotion {
                    Image(systemName: "ellipsis").font(.system(size: 10, weight: .bold))
                } else {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12).tint(statusColor)
                }
            } else {
                Image(systemName: call.status == .completed ? "checkmark" : call.status == .failed ? "exclamationmark" : "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .foregroundStyle(statusColor)
        .frame(width: 20, height: 20)
        .petGlass()
        .overlay(Circle().stroke(statusColor.opacity(0.3), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

private extension View {
    /// Backs the view with AppKit's `NSGlassEffectView` (macOS 26+), falling back to a behind-window blur.
    /// A nil corner radius makes a capsule (or a circle for square views).
    func petGlass(tint: Color? = nil, cornerRadius: CGFloat? = nil) -> some View {
        background(PetGlassBackground(tint: tint.map(NSColor.init), cornerRadius: cornerRadius))
    }

    func petGlassButton() -> some View { buttonStyle(PetGlassButtonStyle()) }
}

private struct PetGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GlassButton(configuration: configuration)
    }

    private struct GlassButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .frame(minWidth: 30, minHeight: 30)
                .contentShape(Capsule())
                .petGlass()
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }
}

private struct PetGlassBackground: NSViewRepresentable {
    let tint: NSColor?
    let cornerRadius: CGFloat?

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) { return PetGlassView() }
        let view = PetBlurView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if #available(macOS 26.0, *), let glass = view as? PetGlassView {
            glass.tintColor = tint
            glass.fixedCornerRadius = cornerRadius
        } else if let blur = view as? PetBlurView {
            blur.tint = tint
            blur.fixedCornerRadius = cornerRadius
        }
    }
}

/// System Liquid Glass that never takes clicks, so SwiftUI controls on top stay interactive.
@available(macOS 26.0, *)
final class PetGlassView: NSGlassEffectView {
    var fixedCornerRadius: CGFloat? { didSet { needsLayout = true } }
    override func layout() {
        super.layout()
        cornerRadius = fixedCornerRadius ?? min(bounds.width, bounds.height) / 2
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PetBlurView: NSVisualEffectView {
    var fixedCornerRadius: CGFloat? { didSet { needsLayout = true } }
    var tint: NSColor? { didSet { layer?.backgroundColor = tint?.cgColor } }
    override func layout() {
        super.layout()
        wantsLayer = true
        layer?.cornerRadius = fixedCornerRadius ?? min(bounds.width, bounds.height) / 2
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Shows up to `visibleLines` of text; longer text slowly scrolls down and back up so it can be read in full.
private struct AutoScrollingText: View {
    let text: String
    let visibleLines: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentHeight: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var cycle = 0

    private static let font = NSFont.systemFont(ofSize: 14, weight: .medium)
    private static let pointsPerSecond: CGFloat = 18
    private static let edgePause: Duration = .seconds(2)

    private var viewportHeight: CGFloat {
        ceil((Self.font.ascender - Self.font.descender + Self.font.leading) * CGFloat(visibleLines))
    }
    private var overflow: CGFloat { max(0, contentHeight - viewportHeight) }

    var body: some View {
        if overflow > 0 && reduceMotion {
            // No automatic motion: let people scroll the text themselves.
            ScrollView(.vertical) { label }
                .frame(height: viewportHeight)
        } else {
            label
                .offset(y: offset)
                .frame(height: overflow > 0 ? viewportHeight : nil, alignment: .top)
                .clipped()
                .mask(edgeFade)
                .task(id: AutoScrollKey(cycle: cycle, isOverflowing: overflow > 0)) { await scrollLoop() }
        }
    }

    private var label: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            .onChange(of: text) { old, new in
                // A brand-new message starts from the top; a streaming reply keeps its scroll position.
                if !new.hasPrefix(old) {
                    offset = 0
                    cycle += 1
                }
            }
    }

    private var edgeFade: some View {
        let fade: CGFloat = overflow > 0 ? 0.12 : 0
        return LinearGradient(stops: [
            .init(color: offset < 0 ? .clear : .black, location: 0),
            .init(color: .black, location: fade),
            .init(color: .black, location: 1 - fade),
            .init(color: -offset < overflow - 1 ? .clear : .black, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    private func scrollLoop() async {
        guard overflow > 0 else {
            offset = 0
            return
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.edgePause)
            // Read the overflow each pass so a reply that keeps streaming in is scrolled to its new end.
            let distance = overflow
            guard !Task.isCancelled, distance > 0 else { return }
            await scroll(to: -distance, over: distance)
            try? await Task.sleep(for: Self.edgePause)
            guard !Task.isCancelled else { return }
            await scroll(to: 0, over: distance)
        }
    }

    private func scroll(to target: CGFloat, over distance: CGFloat) async {
        let seconds = Double(distance / Self.pointsPerSecond)
        withAnimation(.linear(duration: seconds)) { offset = target }
        try? await Task.sleep(for: .seconds(seconds))
    }
}

private struct AutoScrollKey: Hashable {
    let cycle: Int
    let isOverflowing: Bool
}

private struct DesktopVoiceWaveform: View {
    let level: Float
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var amplitude: CGFloat { isActive ? CGFloat(sqrt(min(1, max(0, level)))) : 0 }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(0..<8, id: \.self) { index in
                    let weight = CGFloat(0.3 + 0.7 * abs(sin(Double(index + 1) * 1.7)))
                    Capsule()
                        .fill(isActive ? Color(red: 0.76, green: 0.36, blue: 0.20) : Color.secondary.opacity(0.5))
                        .frame(maxWidth: .infinity)
                        .frame(height: 3 + (geometry.size.height - 3) * amplitude * weight)
                }
            }
            .frame(height: geometry.size.height)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: amplitude)
        .accessibilityHidden(true)
    }
}

/// Marks just the visible controls/bubble as interactive; the rest of the window is transparent to clicks.
private struct DesktopPetHitRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DesktopPetHitRegionView { DesktopPetHitRegionView() }
    func updateNSView(_ view: DesktopPetHitRegionView, context: Context) {}
}

final class DesktopPetHitRegionView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct DesktopPetDragHandle: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> DesktopPetDragView { DesktopPetDragView(name: name) }
    func updateNSView(_ view: DesktopPetDragView, context: Context) { view.label.stringValue = name }
}

final class DesktopPetDragView: NSView {
    let label = NSTextField(labelWithString: "")
    init(name: String) {
        super.init(frame: .zero)
        label.stringValue = name
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        toolTip = "Drag the name bar or your pet to move them around your desktop."
        setAccessibilityLabel("Move \(name) around your desktop")
    }
    required init?(coder: NSCoder) { fatalError("Use init(name:)") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { (window as? DesktopPetPanel)?.drag(with: event) }
}

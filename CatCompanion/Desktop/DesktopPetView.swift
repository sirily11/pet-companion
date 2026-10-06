import AppKit
import SwiftUI

@MainActor
struct DesktopPetView: View {
    @ObservedObject var behavior: DesktopPetBehavior
    @ObservedObject var voice: DesktopPetVoiceState
    @ObservedObject private var live: LiveClient
    @ObservedObject private var audio: AudioController
    @Environment(\.openWindow) private var openWindow
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

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if let speech = bubbleText {
                    VStack(spacing: 0) {
                        VStack(spacing: 6) {
                            Text(speech)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .multilineTextAlignment(.center).lineLimit(conversationError == nil ? 4 : 3)
                                .fixedSize(horizontal: false, vertical: true)
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
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(Color(red: 1, green: 0.98, blue: 0.94), in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.brown.opacity(0.2), lineWidth: 1))
                        .background(DesktopPetHitRegion())
                        BubbleTail().fill(Color(red: 1, green: 0.98, blue: 0.94)).frame(width: 18, height: 10)
                    }
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
                    .overlay(alignment: .bottom) {
                        PetReactionStatus(character: character, onSettings: showSettings)
                            .padding(.horizontal, 16)
                            .background(DesktopPetHitRegion())
                    }
                    .accessibilityAction(named: "Talk with Gemini Live") { voice.onToggleConversation?() }
                    .accessibilityAction(named: "Hide desktop pet", onHide)
            }

            HStack(spacing: 10) {
                DesktopPetDragHandle(name: behavior.character?.package?.manifest.name ?? "Your pet")
                    .frame(maxWidth: .infinity, minHeight: 30)
                Button { voice.onToggleConversation?() } label: {
                    if isConversationStarted { Image(systemName: "stop.fill") }
                    else { Label("Talk", systemImage: "mic.fill") }
                }
                .help(conversationButtonTitle).accessibilityLabel(conversationButtonTitle)
                .foregroundStyle(isConversationStarted ? Color(red: 0.76, green: 0.36, blue: 0.20) : .primary)
                if voice.isRequestingMicrophone || live.state == .connecting {
                    ProgressView().controlSize(.mini).frame(width: 20)
                } else if live.state == .connected {
                    DesktopVoiceWaveform(level: audio.isSpeaking ? voice.outputLevel : audio.microphoneLevel,
                        isActive: audio.isSpeaking || (audio.isCapturing && !audio.isListeningPaused))
                        .frame(width: 32, height: 18)
                        .help(audio.isSpeaking ? "Pet speaking" : audio.isMicrophoneEnabled ? "Listening" : "Microphone muted")
                    Button { voice.onToggleMicrophone?() } label: {
                        Image(systemName: audio.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill")
                    }
                    .help(audio.isMicrophoneEnabled ? "Mute microphone" : "Unmute microphone")
                    .accessibilityLabel(audio.isMicrophoneEnabled ? "Mute microphone" : "Unmute microphone")
                }
                Button { behavior.requestMood() } label: { Image(systemName: "sparkles") }
                    .help("Let your pet choose a new mood").accessibilityLabel("New pet mood")
                    .disabled(behavior.isThinking || isConversationStarted || audio.isSpeaking)
                Button(action: onHide) { Image(systemName: "xmark") }
                    .help("Hide desktop pet").accessibilityLabel("Hide desktop pet")
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .background(.regularMaterial, in: Capsule())
            .background(DesktopPetHitRegion())
            .padding(.horizontal, 22)
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

private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
        }
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
        toolTip = "Drag to move your pet. You can also Option-drag the pet."
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

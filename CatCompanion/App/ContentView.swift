import SwiftUI

private let ink = Color(red: 0.29, green: 0.22, blue: 0.18)
private let accent = Color(red: 0.76, green: 0.36, blue: 0.20)
private let paper = Color(red: 0.98, green: 0.96, blue: 0.92)

struct ContentView: View {
    @ObservedObject var coordinator: CompanionCoordinator
    var body: some View {
        HStack(spacing: 0) {
            StudioPanel(character: coordinator.character, audio: coordinator.audio, coordinator: coordinator)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(ink.opacity(0.10)).frame(width: 1)
            ConversationPanel(live: coordinator.live, audio: coordinator.audio, coordinator: coordinator)
                .frame(width: 330)
        }
        .background(paper)
        .foregroundStyle(ink)
        .tint(accent)
        .preferredColorScheme(.light)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    CompanionMenuItems(coordinator: coordinator)
                } label: {
                    Label("Pets", systemImage: "pawprint")
                }
                .disabled(coordinator.isImporting)
                .help("Switch or manage your saved pets")
            }
            ToolbarItem(placement: .automatic) {
                DesktopPetButton(coordinator: coordinator, desktopPet: coordinator.desktopPet)
            }
            ToolbarItem(placement: .automatic) {
                Button { coordinator.showingImport = true } label: { Label("Import pet companion", systemImage: "square.and.arrow.down") }
                    .disabled(coordinator.isImporting)
            }
            ToolbarItem(placement: .automatic) {
                Button { coordinator.showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            }
        }
        .sheet(isPresented: $coordinator.showingSettings) { GatewaySettingsView(settings: coordinator.settings, models: coordinator.localModelStore, onChange: coordinator.settingsDidChange, onDecisionChange: coordinator.decisionSettingsDidChange) }
        .sheet(isPresented: Binding(
            get: { coordinator.showingImport && !coordinator.showingPets },
            set: { coordinator.showingImport = $0 }
        )) { ImportCompanionView(coordinator: coordinator) }
        .sheet(isPresented: $coordinator.showingPets) { ManageCompanionsView(coordinator: coordinator) }
        .alert("Couldn’t update pets", isPresented: Binding(
            get: { coordinator.petManagementError != nil && !coordinator.showingPets },
            set: { if !$0 { coordinator.petManagementError = nil } }
        )) {
            Button("OK", role: .cancel) { coordinator.petManagementError = nil }
        } message: { Text(coordinator.petManagementError ?? "") }
        .overlay(alignment: .top) {
            if let notice = coordinator.petNotice {
                CompanionNoticeView(message: notice)
            }
        }
    }
}

struct CompanionMenuItems: View {
    @ObservedObject var coordinator: CompanionCoordinator

    var body: some View {
        Group {
            ForEach(coordinator.companions, id: \.root) { package in
                Button { coordinator.selectCompanion(package) } label: {
                    Label(package.manifest.name,
                          systemImage: coordinator.character.package?.root == package.root ? "checkmark" : "pawprint")
                }
                .disabled(coordinator.character.package?.root == package.root)
            }
            if !coordinator.companions.isEmpty { Divider() }
            Button { coordinator.showingPets = true } label: {
                Label("Manage Pets…", systemImage: "square.stack.3d.up")
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
        .disabled(coordinator.isImporting)
    }
}

struct CompanionNoticeView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.callout)
            .padding(12).background(.regularMaterial, in: Capsule()).padding(.top, 12)
            .accessibilityLabel(message)
            .allowsHitTesting(false)
    }
}

struct DesktopPetButton: View {
    @ObservedObject var coordinator: CompanionCoordinator
    @ObservedObject var desktopPet: DesktopPetController
    var body: some View {
        Button { coordinator.toggleDesktopPet() } label: {
            Label(desktopPet.isVisible ? "Hide desktop pet" : "Show on desktop", systemImage: "desktopcomputer")
        }
        .disabled(coordinator.character.package == nil || coordinator.isImporting)
        .help(desktopPet.isVisible ? "Hide your desktop companion" : "Let your pet keep you company on the desktop")
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .alert("Couldn’t show desktop pet", isPresented: Binding(
            get: { desktopPet.error != nil },
            set: { if !$0 { desktopPet.clearError() } }
        )) { Button("OK", role: .cancel) { desktopPet.clearError() } }
        message: { Text(desktopPet.error ?? "") }
    }
}

private struct StudioPanel: View {
    @ObservedObject var character: CatSceneController
    @ObservedObject var audio: AudioController
    @ObservedObject var coordinator: CompanionCoordinator
    @State private var showControls = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("PetPaw").font(.system(size: 11, weight: .semibold, design: .rounded)).tracking(2.5).foregroundStyle(accent)
                    Text(character.package?.manifest.name ?? "A little company.").font(.system(size: 28, weight: .medium, design: .serif))
                }
                Spacer()
                if character.package != nil {
                    Button { character.resetCamera() } label: { Image(systemName: "viewfinder") }.help("Reset camera")
                    Toggle(isOn: $character.showSkeleton) { Label("Skeleton", systemImage: "point.3.connected.trianglepath.dotted") }
                        .toggleStyle(.button).help("Show the \(RigJoint.skeleton.count) control joints")
                }
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 12)
            Group {
                if character.package == nil {
                    CompanionWelcomeView(error: coordinator.importError, isImporting: coordinator.isImporting) {
                        coordinator.showingImport = true
                    }
                } else {
                    ZStack(alignment: .bottom) {
                        CharacterStage(controller: character)
                            .id(ObjectIdentifier(character))
                            .accessibilityAction(named: "Tap your pet") { character.interact(.tap) }
                            .accessibilityAction(named: "Pet gently") { character.interact(.petting) }
                            .accessibilityAction(named: "Cuddle your pet") { character.interact(.longPress) }
                            .accessibilityAction(named: "Play with your pet") { character.interact(.swipe(SIMD2(1, 0))) }
                            .overlay(alignment: .top) {
                                PetReactionStatus(character: character) { coordinator.showingSettings = true }
                                    .padding(12)
                            }
                        if let error = character.loadError {
                            ContentUnavailableView("Couldn’t load the companion", systemImage: "exclamationmark.triangle", description: Text(error))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        if let pose = character.pose {
                            HStack(spacing: 8) {
                                Circle().fill(audio.isSpeaking ? accent : Color.green.opacity(0.7)).frame(width: 6, height: 6)
                                Text(audio.isSpeaking ? "Speaking" : character.reactionPose?.title ?? character.reaction?.title ?? pose.title).font(.system(size: 12, weight: .medium))
                                Text("· Tap, stroke or hold").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .help("Move the cursor to catch their eye. Swipe across your pet to play. Drag the background or Option-drag to orbit; scroll the background to zoom.")
                            .background(.regularMaterial, in: Capsule()).padding(.bottom, 18)
                            .allowsHitTesting(false)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if character.package != nil { VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("A mood for every moment").font(.system(size: 16, weight: .medium, design: .serif))
                    Spacer()
                    Button { showControls.toggle() } label: { Label("Joint controls", systemImage: "slider.horizontal.3") }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(accent)
                        .hidden()
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                    ForEach(character.poses) { pose in
                        Button { character.setPose(pose) } label: {
                            VStack(spacing: 8) {
                                Image(systemName: pose.symbol).font(.system(size: 19, weight: .light))
                                Text(pose.title).font(.system(size: 11, weight: .medium))
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(character.pose == pose ? accent.opacity(0.12) : .white.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(character.pose == pose ? accent.opacity(0.45) : ink.opacity(0.08)))
                            .foregroundStyle(character.pose == pose ? accent : ink.opacity(0.7))
                        }.buttonStyle(.plain)
                            .accessibilityLabel("\(pose.title) pose")
                            .accessibilityAddTraits(character.pose == pose ? .isSelected : [])
                    }
                }
                if showControls {
                    VStack(spacing: 10) {
                        JointSlider(title: "Head pitch", value: $character.headPitch, range: -0.35...0.35)
                        JointSlider(title: "Head turn", value: $character.headYaw, range: -0.5...0.5)
                        JointSlider(title: "Head tilt", value: $character.headTilt, range: -0.35...0.35)
                        JointSlider(title: "Paw lift", value: $character.pawLift, range: 0...0.9)
                        JointSlider(title: "Tail swing", value: $character.tailSwing, range: -0.5...0.5)
                        JointSlider(title: "Mouth open", value: $character.mouthPreview, range: 0...1, percent: true)
                    }.padding(14).background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                }
                HStack {
                    Text("Your voice. Their personality.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button { coordinator.demo() } label: { Label("Try a voice demo", systemImage: "waveform") }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(accent)
                }
            }.padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 24) }
        }
    }
}

/// A welcome surface replaces the 3D stage until a companion is imported.
private struct CompanionWelcomeView: View {
    let error: String?
    let isImporting: Bool
    let onImport: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveringImport = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    welcomeCard
                        .frame(maxWidth: 420)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 32)
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .background {
                RadialGradient(colors: [.white.opacity(0.8), paper.opacity(0.3), paper],
                               center: UnitPoint(x: 0.5, y: 0.42), startRadius: 30, endRadius: 460)
            }
        }
    }

    private var welcomeCard: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(accent.opacity(0.07))
                    .frame(width: 92, height: 92)
                    .rotationEffect(.degrees(-10))
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 1, green: 0.95, blue: 0.87), Color(red: 0.97, green: 0.87, blue: 0.75)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.85), lineWidth: 1))
                    .frame(width: 80, height: 80)
                    .shadow(color: accent.opacity(0.10), radius: 12, y: 6)
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(accent)
                Image(systemName: "sparkle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(accent.opacity(0.7))
                    .offset(x: 49, y: -36)
            }
            .frame(height: 100).accessibilityHidden(true)

            Text("Bring your pet to life.")
                .font(.system(size: 29, weight: .medium, design: .serif))
                .multilineTextAlignment(.center)
                .padding(.top, 22)
                .accessibilityAddTraits(.isHeader)
            Text("A familiar face. A personality all their own.\nImport a companion to make this space theirs.")
                .font(.system(size: 13)).foregroundStyle(ink.opacity(0.72))
                .multilineTextAlignment(.center).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            HStack(spacing: 8) {
                packageFeature("Personality", symbol: "heart")
                packageFeature("Poses", symbol: "face.smiling")
                packageFeature("3D model", symbol: "cube")
            }
            .padding(.top, 24)

            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 18)
            }

            Button(action: onImport) {
                HStack(spacing: 9) {
                    if isImporting { ProgressView().controlSize(.small).tint(.white) }
                    else { Image(systemName: "square.and.arrow.down").font(.system(size: 15, weight: .medium)) }
                    Text(isImporting ? "Importing companion…" : "Import pet companion")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(Color(red: 0.70, green: 0.30, blue: 0.16).opacity(hoveringImport ? 0.94 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
                .shadow(color: accent.opacity(hoveringImport ? 0.23 : 0.16), radius: 9, y: 4)
            }
            .buttonStyle(.plain).disabled(isImporting)
            .onHover { hoveringImport = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hoveringImport)
            .help("Import a companion ZIP or folder (⌘I)")
            .padding(.top, 28)

            Text("ZIP or folder  ·  ⌘I")
                .font(.system(size: 11)).foregroundStyle(ink.opacity(0.70))
                .padding(.top, 13)
        }
        .padding(32)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.92), .white.opacity(0.66)], startPoint: .top, endPoint: .bottom))
                .shadow(color: ink.opacity(0.06), radius: 28, y: 12)
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white.opacity(0.95), lineWidth: 1))
        }
    }

    private func packageFeature(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ink.opacity(0.70))
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(paper.opacity(0.8), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct JointSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var percent = false
    var body: some View {
        HStack {
            Text(title).font(.system(size: 11)).frame(width: 76, alignment: .leading)
            Slider(value: $value, in: range)
            Text(percent ? "\(Int(value * 100))%" : "\(Int(value * 180 / .pi))°").font(.system(size: 10, design: .monospaced)).frame(width: 34, alignment: .trailing)
        }
    }
}

private struct ConversationPanel: View {
    @ObservedObject var live: ConversationSession
    @ObservedObject var audio: AudioController
    @ObservedObject var coordinator: CompanionCoordinator
    @State private var draft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Conversation").font(.system(size: 20, weight: .medium, design: .serif))
                Spacer()
                Circle().fill(live.state == .connected ? .green : ink.opacity(0.2)).frame(width: 7, height: 7)
            }
            Text(live.state == .connected ? "\(live.provider == .gemini ? "Gemini Live" : "GPT Realtime") is here. Say hello." : "Talk, wonder, or just say hello.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if live.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 28, weight: .ultraLight)).foregroundStyle(accent.opacity(0.8))
                                Text("Someone to share\nyour day with.").font(.system(size: 23, weight: .regular, design: .serif))
                                Text("Import a companion and start a conversation. Your pet will listen and respond with a voice and a pose.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                            }.padding(.top, 48).padding(.bottom, 24)
                        }
                        ForEach(live.messages) { line in
                            if let call = line.toolCall {
                                ConversationToolCallView(call: call, sources: line.sources)
                            } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(line.role == "user" ? "YOU" : coordinator.character.package?.manifest.name.uppercased() ?? "PET").font(.system(size: 9, weight: .semibold)).tracking(1.8).foregroundStyle(accent)
                                Text(line.text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                                if !line.sources.isEmpty {
                                    Text("SOURCES").font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary).padding(.top, 4)
                                    ForEach(line.sources) { source in
                                        Link(destination: source.url) {
                                            Label(source.title, systemImage: "link").font(.system(size: 11)).lineLimit(2)
                                        }
                                    }
                                }
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(line.role == "user" ? .white.opacity(0.7) : accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                }
                .onChange(of: live.messages.last?.id) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: live.messages.last?.text) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
            if let error = live.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).font(.system(size: 11)).lineSpacing(3)
                    Button { live.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.foregroundStyle(accent).padding(12).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(spacing: 12) {
                VoiceModelPicker(settings: coordinator.settings, catalog: coordinator.modelCatalog,
                                 coordinator: coordinator)
                HStack {
                    Toggle("Conversation poses", isOn: $coordinator.automaticPoses).font(.system(size: 11)).toggleStyle(.checkbox)
                    Spacer()
                    Text(live.poseSource).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    TextField("Or type a message…", text: $draft).textFieldStyle(.plain).font(.system(size: 12))
                        .onSubmit(send).disabled(live.state != .connected)
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 21)) }
                        .buttonStyle(.plain).disabled(live.state != .connected || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(12).background(.white, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink.opacity(0.10)))
                HStack(spacing: 8) {
                    Button {
                        coordinator.toggleConversation()
                    } label: {
                        Label(live.state == .connected ? "End conversation" : live.state == .connecting ? "Cancel connection" : "Start conversation",
                              systemImage: live.state == .disconnected ? "mic.fill" : "stop.fill")
                            .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .buttonStyle(.plain).background(accent, in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.white)
                    .disabled(coordinator.isRequestingMicrophone || coordinator.isImporting || coordinator.character.package == nil)
                    if live.state == .connected {
                        Button { coordinator.toggleMicrophone() } label: {
                            Image(systemName: audio.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill").frame(width: 38, height: 38)
                        }.buttonStyle(.plain).background(.white, in: RoundedRectangle(cornerRadius: 10))
                            .help(audio.isMicrophoneEnabled ? "Mute microphone" : "Unmute microphone")
                    }
                }
                if live.state == .connected {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: !audio.isMicrophoneEnabled ? "mic.slash.fill" : audio.isListeningPaused ? "speaker.wave.2.fill" : "mic.fill")
                                .foregroundStyle(accent)
                            Text(!audio.isMicrophoneEnabled ? "Microphone muted" : audio.isListeningPaused ? "Cat speaking · Microphone paused" : "Listening")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        MicrophoneWaveform(level: audio.microphoneLevel, isActive: audio.isCapturing && !audio.isListeningPaused)
                            .frame(height: 28)
                    }
                }
            }
        }.padding(24).background(Color.white.opacity(0.25))
    }
    private func send() {
        live.sendText(draft)
        draft = ""
    }
}

private struct ConversationToolCallView: View {
    let call: ConversationToolCall
    let sources: [WebSource]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("TOOL CALL", systemImage: "wrench.and.screwdriver")
                    .font(.system(size: 9, weight: .semibold)).tracking(1.4)
                Spacer()
                if call.status == .running { ProgressView().controlSize(.mini) }
                Label(call.status.rawValue, systemImage: call.status.symbol)
                    .font(.system(size: 10))
            }.foregroundStyle(call.status == .failed ? Color.red : accent)
            Text(call.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
            if let query = call.query, !query.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Query").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Text(query).font(.system(size: 12)).lineSpacing(3).textSelection(.enabled)
                }
            }
            if let result = call.result, !result.isEmpty {
                if call.status == .completed {
                    DisclosureGroup("Result") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(result).lineSpacing(3).textSelection(.enabled)
                            ForEach(sources) { source in
                                Link(destination: source.url) {
                                    Label(source.title, systemImage: "link").lineLimit(2)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    }.font(.system(size: 11))
                } else {
                    Text(result).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineSpacing(3).textSelection(.enabled)
                }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(ink.opacity(0.08)))
    }
}

private struct MicrophoneWaveform: View {
    let level: Float
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let barCount = 40

    private var amplitude: CGFloat {
        isActive ? CGFloat(sqrt(min(1, max(0, level)))) : 0
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(isActive ? accent : ink.opacity(0.22))
                        .frame(maxWidth: .infinity)
                        .frame(height: 3 + max(0, geometry.size.height - 3) * amplitude * weight(for: index))
                }
            }
            .frame(height: geometry.size.height)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: amplitude)
        .accessibilityHidden(true)
    }

    private func weight(for index: Int) -> CGFloat {
        let position = Double(index) / Double(barCount - 1)
        let envelope = 0.2 + 0.8 * sin(.pi * position)
        let detail = 0.4 + 0.6 * abs(cos(.pi * 10 * position))
        return CGFloat(envelope * detail)
    }
}

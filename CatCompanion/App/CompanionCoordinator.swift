import Combine
import Foundation
import SwiftUI

@MainActor
final class CompanionCoordinator: ObservableObject {
    @Published private(set) var character = CatSceneController()
    @Published private(set) var companions: [CompanionPackage] = []
    private let companionStore: CompanionStore
    private var noticeTask: Task<Void, Never>?
    let audio: AudioController
    let live: LiveClient
    let settings: GatewaySettings
    let desktopPet: DesktopPetController
    let reactions: PetReactionBrain
    private var subscriptions = Set<AnyCancellable>()
    private var connectionAttempt = UUID()
    private var editorWindowCount = 0
    @Published var automaticPoses = true { didSet { live.automaticallyChoosePoses = automaticPoses } }
    @Published var showingSettings = false
    @Published var showingImport = false
    @Published var showingPets = false
    @Published private(set) var isImporting = false
    @Published var importError: String?
    @Published private(set) var petNotice: String?
    @Published var petManagementError: String?
    @Published var isRequestingMicrophone = false

    init(companionStore: CompanionStore = CompanionStore(), settings: GatewaySettings? = nil,
         decideReaction: PetReactionBrain.Decide? = nil) {
        let audio = AudioController()
        let live = LiveClient()
        let settings = settings ?? GatewaySettings()
        self.audio = audio
        self.live = live
        self.settings = settings
        self.reactions = PetReactionBrain(history: live.interactionHistory, key: { try settings.key() }, decide: decideReaction)
        self.desktopPet = DesktopPetController(voice: DesktopPetVoiceState(live: live, audio: audio))
        self.companionStore = companionStore
        desktopPet.onShowCharacter = { [weak self] character in self?.reactions.bind(character, surface: "desktop") }
        desktopPet.behavior.onRequestMood = { [weak self] in
            guard let self, let character = self.desktopPet.behavior.character else { return }
            self.reactions.requestMood(for: character)
        }
        desktopPet.voice.onToggleConversation = { [weak self] in self?.toggleConversation() }
        desktopPet.voice.onToggleMicrophone = { [weak self] in self?.toggleMicrophone() }
        desktopPet.voice.onShowSettings = { [weak self] in self?.showingSettings = true }
        desktopPet.onHide = { [weak self] in self?.disconnect() }
        audio.onLipFrame = { [weak self] frame in
            guard let self else { return }
            self.character.setLipFrame(frame)
            self.desktopPet.behavior.character?.setLipFrame(frame)
            if self.desktopPet.voice.outputLevel != frame.open { self.desktopPet.voice.outputLevel = frame.open }
        }
        audio.onInputAudio = { [weak self] in self?.live.sendAudio($0) }
        live.canSendAudio = { [weak self] in
            guard let self else { return false }
            return self.audio.isCapturing && !self.audio.isListeningPaused
        }
        audio.onError = { [weak self] message in self?.live.error = message }
        live.onAudio = { [weak self] data in
            guard let self else { return }
            self.audio.beginResponse()
            do { try self.audio.playPCM(data) }
            catch { self.disconnect(); self.live.error = error.localizedDescription }
        }
        live.onResponseDone = { [weak self] in self?.audio.finishResponse() }
        live.onTranscript = { [weak self] in self?.desktopPet.voice.reply = $0 }
        live.onInterruption = { [weak self] in self?.audio.stopPlayback() }
        live.onPose = { [weak self] pose in
            guard let self, self.automaticPoses else { return }
            if let definition = self.character.poses.first(where: { $0.id == pose }) { self.character.setPose(definition) }
            if let desktop = self.desktopPet.behavior.character,
               let definition = desktop.poses.first(where: { $0.id == pose }) { desktop.setPose(definition) }
        }
        live.onReady = { [weak self] in
            guard let self else { return }
            do { try self.audio.startCapture() }
            catch { self.live.disconnect(); self.live.error = error.localizedDescription }
        }
        live.onDisconnect = { [weak self] in self?.audio.stopCapture(); self?.audio.stopPlayback() }
        Publishers.CombineLatest3(live.$state, audio.$isSpeaking, $isRequestingMicrophone)
            .sink { [weak self] values in
                guard let self else { return }
                let (state, speaking, requesting) = values
                self.desktopPet.voice.isRequestingMicrophone = requesting
                self.desktopPet.behavior.setConversationActive(state != .disconnected || speaking || requesting)
            }
            .store(in: &subscriptions)
        do { companions = try companionStore.installed() }
        catch { petManagementError = "Couldn’t load your saved pets. \(error.localizedDescription)" }
        do {
            if let package = try companionStore.current() {
                let restored = CatSceneController(package: package)
                if let error = restored.loadError { importError = error }
                else {
                    character = restored
                    live.companion = package
                    if !companions.contains(where: { $0.root == package.root }) { companions.append(package) }
                }
            }
        } catch { importError = "Couldn’t restore the saved companion. Import its folder or ZIP again." }
        reactions.bind(character, surface: "editor")
    }

    func connect() async {
        guard !isRequestingMicrophone, !isImporting, live.state == .disconnected else { return }
        guard character.package != nil else { showingImport = true; return }
        let attempt = UUID()
        connectionAttempt = attempt
        desktopPet.voice.hasAttemptedConversation = true
        desktopPet.voice.reply = nil
        live.error = nil
        let key: String
        do { key = try settings.key() }
        catch {
            live.error = error.localizedDescription
            showingSettings = true
            if desktopPet.isVisible { desktopPet.voice.needsSettings = true }
            return
        }
        isRequestingMicrophone = true
        let requestedCharacter = character
        let allowed = await audio.requestMicrophone()
        guard connectionAttempt == attempt else { return }
        isRequestingMicrophone = false
        guard character === requestedCharacter, !isImporting else { return }
        guard allowed else {
            live.error = "Allow microphone access in System Settings → Privacy & Security → Microphone, then try again."
            return
        }
        audio.stopPlayback()
        await live.connect(key: key)
    }

    @discardableResult
    func importCompanion(from url: URL) async -> Bool {
        guard !isImporting else { return false }
        isImporting = true
        importError = nil
        petManagementError = nil
        noticeTask?.cancel()
        petNotice = nil
        defer { isImporting = false }
        var prepared: CompanionPackage?
        do {
            let store = companionStore
            let package = try await Task.detached(priority: .userInitiated) { try store.prepare(url) }.value
            prepared = package
            let candidate = CatSceneController(package: package)
            if let error = candidate.loadError { throw CompanionImportError.invalid(error) }
            let savedCompanions = try store.installed()
            try store.activate(package)
            prepared = nil
            companions = savedCompanions
            use(candidate)
            showingImport = false
            showNotice("\(package.manifest.name) imported")
            return true
        } catch {
            if let prepared { companionStore.discard(prepared) }
            importError = error.localizedDescription
            return false
        }
    }

    func selectCompanion(_ saved: CompanionPackage) {
        guard !isImporting, saved.root != character.package?.root,
              companions.contains(where: { $0.root == saved.root }) else { return }
        petManagementError = nil
        do {
            let package = try CompanionPackage.load(from: saved.root)
            let candidate = CatSceneController(package: package)
            if let error = candidate.loadError { throw CompanionImportError.invalid(error) }
            try companionStore.activate(package)
            use(candidate)
            showNotice("Switched to \(package.manifest.name)")
        } catch { petManagementError = error.localizedDescription }
    }

    func removeCompanion(_ package: CompanionPackage) {
        guard !isImporting, companions.contains(where: { $0.root == package.root }) else { return }
        petManagementError = nil
        let removingActive = character.package?.root == package.root
        var replacement: CatSceneController?
        if removingActive {
            for saved in companions where saved.root != package.root {
                guard let available = try? CompanionPackage.load(from: saved.root) else { continue }
                let candidate = CatSceneController(package: available)
                if candidate.loadError == nil { replacement = candidate; break }
            }
        }
        do {
            try companionStore.remove(package, replacingWith: replacement?.package)
            companions.removeAll { $0.root == package.root }
            if removingActive { use(replacement ?? CatSceneController()) }
            showNotice("\(package.manifest.name) removed")
        } catch { petManagementError = error.localizedDescription }
    }

    private func use(_ candidate: CatSceneController) {
        disconnect()
        character.clearInteraction()
        reactions.reset()
        character = candidate
        reactions.bind(candidate, surface: "editor")
        live.companion = candidate.package
        importError = nil
        if desktopPet.isVisible {
            if let package = candidate.package { desktopPet.show(package: package) }
            else { desktopPet.hide() }
        }
    }

    private func showNotice(_ message: String) {
        noticeTask?.cancel()
        petNotice = message
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.petNotice = nil
        }
    }

    func disconnect() {
        connectionAttempt = UUID()
        isRequestingMicrophone = false
        desktopPet.voice.hasAttemptedConversation = false
        live.disconnect()
    }

    func settingsDidChange() {
        reactions.cancel()
        character.clearInteraction()
        desktopPet.behavior.character?.clearInteraction()
        disconnect()
    }

    func toggleConversation() {
        if isRequestingMicrophone || live.state != .disconnected { disconnect() }
        else { Task { await connect() } }
    }

    func editorDidOpen() {
        editorWindowCount += 1
        desktopPet.voice.isEditorVisible = true
    }

    func editorDidClose() {
        editorWindowCount = max(0, editorWindowCount - 1)
        desktopPet.voice.isEditorVisible = editorWindowCount > 0
        if editorWindowCount == 0 && !desktopPet.isVisible { disconnect() }
    }

    func toggleDesktopPet() {
        if desktopPet.isVisible { desktopPet.hide() }
        else if let package = character.package { desktopPet.show(package: package) }
        else { showingImport = true }
    }

    func toggleMicrophone() {
        if audio.isMicrophoneEnabled { audio.stopCapture(); live.clearInput() }
        else {
            do { try audio.startCapture() }
            catch { live.error = error.localizedDescription }
        }
    }

    func demo() {
        disconnect()
        guard let pose = character.poses.first(where: { $0.id == "happy" }) ?? character.package?.defaultPose else { return }
        character.setPose(pose)
        audio.playDemo()
    }
}

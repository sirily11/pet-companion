import Combine
import Foundation
import SwiftUI

@MainActor
final class CompanionCoordinator: ObservableObject {
    @Published private(set) var character = CatSceneController()
    private let companionStore: CompanionStore
    let audio = AudioController()
    let live = LiveClient()
    let settings = GatewaySettings()
    @Published var automaticPoses = true { didSet { live.automaticallyChoosePoses = automaticPoses } }
    @Published var showingSettings = false
    @Published var showingImport = false
    @Published private(set) var isImporting = false
    @Published var importError: String?
    @Published private(set) var importNotice: String?
    @Published var isRequestingMicrophone = false

    init(companionStore: CompanionStore = CompanionStore()) {
        self.companionStore = companionStore
        audio.onLipFrame = { [weak self] in self?.character.setLipFrame($0) }
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
        live.onInterruption = { [weak self] in self?.audio.stopPlayback() }
        live.onPose = { [weak self] pose in
            guard let self, self.automaticPoses else { return }
            if let definition = self.character.poses.first(where: { $0.id == pose }) { self.character.setPose(definition) }
        }
        live.onReady = { [weak self] in
            guard let self else { return }
            do { try self.audio.startCapture() }
            catch { self.live.disconnect(); self.live.error = error.localizedDescription }
        }
        live.onDisconnect = { [weak self] in self?.audio.stopCapture(); self?.audio.stopPlayback() }
        do {
            if let package = try companionStore.current() {
                let restored = CatSceneController(package: package)
                if let error = restored.loadError { importError = error }
                else { character = restored; live.companion = package }
            }
        } catch { importError = "Couldn’t restore the saved companion. Import its folder or ZIP again." }

    }

    func connect() async {
        guard !isRequestingMicrophone, !isImporting else { return }
        guard character.package != nil else { showingImport = true; return }
        let key: String
        do { key = try settings.key() }
        catch { live.error = error.localizedDescription; showingSettings = true; return }
        isRequestingMicrophone = true
        let requestedCharacter = character
        let allowed = await audio.requestMicrophone()
        isRequestingMicrophone = false
        guard character === requestedCharacter, !isImporting else { return }
        guard allowed else {
            live.error = "Allow microphone access in System Settings → Privacy & Security → Microphone, then try again."
            return
        }
        audio.stopPlayback()
        await live.connect(key: key)
    }

    func importCompanion(from url: URL) async {
        guard !isImporting else { return }
        isImporting = true
        importError = nil
        importNotice = nil
        defer { isImporting = false }
        var prepared: CompanionPackage?
        do {
            let store = companionStore
            let package = try await Task.detached(priority: .userInitiated) { try store.prepare(url) }.value
            prepared = package
            let candidate = CatSceneController(package: package)
            if let error = candidate.loadError { throw CompanionImportError.invalid(error) }
            try store.activate(package)
            disconnect()
            character = candidate
            live.companion = package
            showingImport = false
            importNotice = "\(package.manifest.name) imported"
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                self?.importNotice = nil
            }
        } catch {
            if let prepared { companionStore.discard(prepared) }
            importError = error.localizedDescription
        }
    }

    func disconnect() { live.disconnect() }

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

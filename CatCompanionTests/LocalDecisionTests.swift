import XCTest
import CryptoKit
@testable import CatCompanion

final class LocalDecisionTests: XCTestCase {
    private func fixture(_ data: Data) -> OpenJevManifest {
        .init(version: 1, checkpointRevision: "fixture", baseRevision: "fixture", files: [
            .init(path: "fixture.bin", url: URL(string: "https://example.com/fixture")!, bytes: Int64(data.count),
                  sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        ])
    }
    @MainActor func testDownloadVerificationRestorationRemovalAndNoBundledWeights() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("model fixture".utf8), manifest = fixture(Data("model fixture".utf8))
        let store = OpenJevModelStore(root: root, manifest: manifest, download: { _, url, progress in
            try bytes.write(to: url); progress(Int64(bytes.count))
        })
        store.startDownload()
        for _ in 0..<100 where !store.isInstalled { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.isInstalled); XCTAssertEqual(store.progress, 1)
        XCTAssertTrue(OpenJevModelStore(root: root, manifest: manifest).isInstalled)
        await store.remove()
        XCTAssertEqual(store.phase, .notInstalled); XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let resources = try FileManager.default.contentsOfDirectory(atPath: Bundle.main.resourcePath!)
        XCTAssertFalse(resources.contains { $0.hasSuffix(".safetensors") || $0 == "head.pt" })
    }

    @MainActor func testCorruptDownloadIsRejectedAndRetryReplacesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OpenJevModelStore(root: root, manifest: fixture(Data("good".utf8)), download: { _, url, progress in
            try Data("oops".utf8).write(to: url); progress(4)
        })
        store.startDownload()
        for _ in 0..<100 where store.phase != .failed { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.phase, .failed); XCTAssertFalse(store.isInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.stagingURL.appendingPathComponent("fixture.bin").path))
        let retry = OpenJevModelStore(root: root, manifest: fixture(Data("good".utf8)), download: { _, url, _ in try Data("good".utf8).write(to: url) })
        retry.startDownload()
        for _ in 0..<100 where !retry.isInstalled { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(retry.isInstalled)
    }

    @MainActor func testPausedPartialDownloadSurvivesRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = fixture(Data("complete".utf8))
        let store = OpenJevModelStore(root: root, manifest: manifest, download: { _, url, progress in
            try Data("com".utf8).write(to: url); progress(3)
            try await Task.sleep(for: .seconds(10))
        })
        store.startDownload()
        for _ in 0..<100 where store.downloadedBytes < 3 { try await Task.sleep(for: .milliseconds(10)) }
        store.pause()
        for _ in 0..<100 where store.phase != .paused { try await Task.sleep(for: .milliseconds(10)) }
        let restored = OpenJevModelStore(root: root, manifest: manifest, download: { _, url, _ in
            XCTAssertEqual(try Data(contentsOf: url), Data("com".utf8))
            try Data("complete".utf8).write(to: url)
        })
        XCTAssertEqual(restored.phase, .paused)
        restored.startDownload()
        for _ in 0..<100 where !restored.isInstalled { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(restored.isInstalled)
    }

    func testReferencePromptAndCalibratedProbabilityMath() throws {
        let question = JevQuestion(id: "pose", instructions: "Choose a pose.", choices: [.init(id: "happy", criteria: "A cheerful pet.")])
        let prompts = try OpenJevPrompts.candidates(state: ["z": ["hello", "你好"], "a": "quote\""], question: question)
        XCTAssertEqual(prompts, ["Context:\n{\"a\": \"quote\\\"\", \"z\": [\"hello\", \"你好\"]}\n\nQuestion: Choose a pose.\nProposed answer: happy: A cheerful pet.\nIs this proposed answer correct? Answer Yes or No."])
        let probabilities = try OpenJevPrompts.probabilities(scores: [1000, 1001], temperature: 2)
        XCTAssertEqual(probabilities.reduce(0, +), 1, accuracy: 1e-12)
        XCTAssertEqual(probabilities[1], 1 / (1 + exp(-0.5)), accuracy: 1e-12)
        XCTAssertThrowsError(try OpenJevPrompts.probabilities(scores: [.nan], temperature: 1))
        XCTAssertThrowsError(try OpenJevHead.read(Data(repeating: 0, count: 100)))
    }

    func testLocalMissingModelDoesNotRequireGatewayKey() async throws {
        let runtime = OpenJevRuntime(directory: URL(fileURLWithPath: "/does-not-exist"), manifest: fixture(Data()))
        let package = try await TestCompanion.package()
        do {
            _ = try await LocalOpenJevClient(runtime: runtime).choosePose(context: .init(interactions: [], companion: package), key: nil)
            XCTFail("Missing model must fail")
        } catch { XCTAssertEqual((error as? OpenJevError)?.localizedDescription, OpenJevError.notInstalled.localizedDescription) }
    }

    @MainActor func testVoiceAndDecisionPreferencesRestoreIndependently() {
        let name = "preferences-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = GatewaySettings(store: MemoryGatewayKeyStore(), defaults: defaults)
        settings.selectModel("google/gemini-3.8-live-extended-thinking")
        settings.provider = .gpt; settings.selectModel("openai/gpt-realtime-mini"); settings.decisionBackend = .local
        let restored = GatewaySettings(store: MemoryGatewayKeyStore(), defaults: defaults)
        XCTAssertEqual(restored.provider, .gpt); XCTAssertEqual(restored.selectedModel, "openai/gpt-realtime-mini")
        XCTAssertEqual(restored.decisionBackend, .local)
        restored.provider = .gemini
        XCTAssertEqual(restored.selectedModel, "google/gemini-3.8-live-extended-thinking")
    }
}

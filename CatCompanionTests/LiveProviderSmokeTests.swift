import XCTest
@testable import CatCompanion

final class LiveProviderSmokeTests: XCTestCase {
    /// Opt-in: use the user's saved Gateway key without exposing it. This sends
    /// a fixed public test prompt, receives audio in memory, and uses no mic.
    @MainActor func testBothProvidersReturnAudioWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["GATEWAY_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_GATEWAY_LIVE_SMOKE=1 to run paid-provider smoke checks.")
        }
        let key = try GatewaySettings().key()
        for provider in LiveChatProvider.allCases {
            let session = ConversationSession()
            session.provider = provider; session.model = provider.defaultModel
            session.companion = try TestCompanion.package()
            session.automaticallyChoosePoses = false
            var bytes = 0, finished = false
            session.onReady = { [weak session] in session?.sendText("Say hello in one brief sentence.") }
            session.onAudio = { bytes += $0.count }
            session.onResponseDone = { finished = true }
            await session.connect(key: key)
            for _ in 0..<1500 {
                if finished || session.error != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNil(session.error, "\(provider.title) connection failed")
            XCTAssertTrue(finished, "\(provider.title) did not finish a reply")
            XCTAssertGreaterThan(bytes, 0, "\(provider.title) returned no PCM audio")
            session.disconnect()
        }
    }
}

import XCTest
@testable import CatCompanion

final class GatewayURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class MemoryGatewayKeyStore: GatewayKeyStore {
    var value: String?
    var failWrites = false
    func load() throws -> String? { value }
    func save(_ key: String) throws {
        if failWrites { throw KeychainError(status: -1) }
        value = key
    }
    func delete() throws { value = nil }
}

@MainActor
final class FakeGatewaySocket: GatewaySocketTransport {
    var maximumMessageSize = 0
    var response: URLResponse?
    var closeCode: URLSessionWebSocketTask.CloseCode = .invalid
    var closeReason: Data?
    var receiveError: Error?
    var sessionReadyEvent = "session-updated"
    var sent: [[String: Any]] = []
    private var pending: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var queue: [URLSessionWebSocketTask.Message] = []
    private var cancelled = false
    func resume() {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        cancelled = true
        pending?.resume(throwing: URLError(.cancelled)); pending = nil
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard !cancelled else { throw URLError(.cancelled) }
        guard case .string(let text) = message,
              let event = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        sent.append(event)
        if event["type"] as? String == "session-update" {
            // Both overrides reproduce confirmed live Gateway transform rejections.
            if let config = event["config"] as? [String: Any],
               config["turnDetection"] != nil || (config["providerOptions"] as? [String: Any])?["tools"] != nil {
                closeCode = .policyViolation
                closeReason = Data("WebSocket transform rejected frame".utf8)
                throw NSError(domain: NSPOSIXErrorDomain, code: 57)
            }
            feed(["type": sessionReadyEvent])
        }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        if cancelled { throw URLError(.cancelled) }
        if let receiveError { throw receiveError }
        if !queue.isEmpty { return queue.removeFirst() }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func feed(_ event: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: event)
        let message = URLSessionWebSocketTask.Message.data(data)
        if let pending { self.pending = nil; pending.resume(returning: message) }
        else { queue.append(message) }
    }
}

final class GatewayTests: XCTestCase {
    private func api() -> GatewayAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayURLProtocol.self]
        return GatewayAPI(session: URLSession(configuration: configuration))
    }
    override func tearDown() { GatewayURLProtocol.handler = nil; super.tearDown() }

    func testNativeTokenRequestAndWebSocketAuthContract() async throws {
        GatewayURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://ai-gateway.vercel.sh/v1/realtime/client-secrets")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            let body = try self.body(of: request)
            XCTAssertEqual(body["model"] as? String, "google/gemini-3.8-live")
            XCTAssertEqual(body["expiresIn"] as? Int, 60)
            return (200, Data(#"{"token":"vcst_test-secret"}"#.utf8))
        }
        let token = try await api().createRealtimeToken(key: "test-key")
        XCTAssertEqual(GatewayAPI.realtimeProtocols(token: token), ["ai-gateway-realtime.v1", "ai-gateway-auth.vcst_test-secret"])
        XCTAssertEqual(GatewayAPI.realtimeURL().host, "ai-gateway.vercel.sh")
    }

    func testGoogleSearchUsesGroundedTextProtocolAndRejectsUngroundedAnswers() async throws {
        GatewayURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v4/ai/language-model")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ai-language-model-id"), GatewayAPI.searchModel)
            XCTAssertEqual(request.value(forHTTPHeaderField: "ai-language-model-specification-version"), "4")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ai-language-model-streaming"), "false")
            let body = try self.body(of: request)
            let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
            XCTAssertEqual(tools.first?["type"] as? String, "provider")
            XCTAssertEqual(tools.first?["id"] as? String, "google.google_search")
            return (200, Data(#"{"content":[{"type":"text","text":"Verified weather."},{"type":"source","sourceType":"url","url":"https://www.hko.gov.hk/","title":"Hong Kong Observatory"},{"type":"source","sourceType":"url","url":"javascript:alert(1)"}]}"#.utf8))
        }
        let result = try await api().searchWeb(key: "test-key", query: "Hong Kong weather")
        XCTAssertEqual(result.text, "Verified weather.")
        XCTAssertEqual(result.sources.map(\.title), ["Hong Kong Observatory"])
        GatewayURLProtocol.handler = { _ in (200, Data(#"{"content":[{"type":"text","text":"An unverified answer."}]}"#.utf8)) }
        do {
            _ = try await api().searchWeb(key: "test-key", query: "Hong Kong weather")
            XCTFail("Search answers need verified source links")
        } catch { XCTAssertTrue(error is GatewayError) }
    }

    @MainActor func testRealtimeSearchFunctionReturnsSourcesAndKeepsConnectionOnSearchFailure() async throws {
        var searchRequests = 0
        GatewayURLProtocol.handler = { request in
            if request.url?.path == "/v1/realtime/client-secrets" {
                return (200, Data(#"{"token":"vcst_test-secret"}"#.utf8))
            }
            searchRequests += 1
            if searchRequests == 1 {
                return (200, Data(#"{"content":[{"type":"text","text":"Verified weather."},{"type":"source","sourceType":"url","url":"https://www.hko.gov.hk/","title":"Hong Kong Observatory"}]}"#.utf8))
            }
            return (503, Data("private-provider-details".utf8))
        }
        let socket = FakeGatewaySocket()
        let client = LiveClient(api: api(), socketFactory: { _, _ in socket })
        client.companion = try TestCompanion.package()
        client.automaticallyChoosePoses = false
        let ready = expectation(description: "Search session ready")
        client.onReady = { ready.fulfill() }
        await client.connect(key: "test-key")
        await fulfillment(of: [ready], timeout: 2)
        let call: [String: Any] = ["type": "function-call-arguments-done", "name": "web_search", "callId": "search-1",
            "arguments": #"{"query":"Hong Kong weather"}"#]
        client.handleEvent(call)
        client.handleEvent(call)
        func waitForOutput(_ callID: String) async throws -> [String: Any] {
            for _ in 0..<100 {
                if let item = socket.sent.compactMap({ $0["item"] as? [String: Any] }).first(where: { $0["callId"] as? String == callID }),
                   let output = item["output"] as? String {
                    XCTAssertEqual(item["type"] as? String, "function-call-output")
                    XCTAssertEqual(item["name"] as? String, "web_search")
                    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Search output was not returned to Gemini")
            return [:]
        }
        let output = try await waitForOutput("search-1")
        XCTAssertEqual(output["text"] as? String, "Verified weather.")
        XCTAssertEqual(searchRequests, 1, "Duplicate function events must not repeat billed search requests")
        client.handleEvent(["type": "audio-transcript-delta", "delta": "Here's the weather."])
        XCTAssertTrue(client.hasSearched)
        XCTAssertEqual(client.messages.last?.sources.first?.title, "Hong Kong Observatory")
        client.handleEvent(["type": "response-done"])
        var failedCall = call
        failedCall["callId"] = "search-2"
        client.handleEvent(failedCall)
        let failure = try await waitForOutput("search-2")
        XCTAssertNotNil(failure["error"])
        XCTAssertFalse(String(describing: failure).contains("private-provider-details"))
        XCTAssertEqual(client.state, .connected, "Search errors must not end the voice session")
        client.disconnect()
    }

    func testNativeJevUsesChoicesAndRejectsUnknownPose() async throws {
        GatewayURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/evaluate")
            let body = try self.body(of: request)
            XCTAssertEqual(body["model"] as? String, "typesafe-ai/jev")
            let questions = try XCTUnwrap(body["questions"] as? [String: Any])
            let pose = try XCTUnwrap(questions["pose"] as? [String: Any])
            XCTAssertEqual(pose["type"] as? String, "choice")
            XCTAssertEqual(Set((pose["criteria"] as? [String: String] ?? [:]).keys), Set(try TestCompanion.package().poses.map(\.id)))
            return (200, Data(#"{"answers":{"pose":{"type":"choice","choice":"wave","probabilities":{"wave":0.96}}}}"#.utf8))
        }
        let decision = try await api().choosePose(key: "test-key", history: [.init(role: "user", text: "Wave hello")], companion: try TestCompanion.package())
        XCTAssertEqual(decision.pose, "wave")
        XCTAssertEqual(decision.confidence, 0.96)
        GatewayURLProtocol.handler = { _ in (200, Data(#"{"answers":{"pose":{"type":"choice","choice":"run","probabilities":{"run":1}}}}"#.utf8)) }
        do { _ = try await api().choosePose(key: "test-key", history: [], companion: try TestCompanion.package()); XCTFail("Unknown motion must be rejected") }
        catch { XCTAssertTrue(error is GatewayError) }
    }

    func testLowConfidencePoseAndAuthenticationErrors() async throws {
        GatewayURLProtocol.handler = { _ in (200, Data(#"{"answers":{"pose":{"type":"choice","choice":"surprised","probabilities":{"surprised":0.2}}}}"#.utf8)) }
        let decision = try await api().choosePose(key: "test-key", history: [], companion: try TestCompanion.package())
        XCTAssertEqual(decision.pose, "idle")
        GatewayURLProtocol.handler = { _ in (401, Data("secret-provider-details".utf8)) }
        do { _ = try await api().createRealtimeToken(key: "test-key"); XCTFail("Unauthorized should fail") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("Settings"))
            XCTAssertFalse(error.localizedDescription.contains("secret-provider-details"))
        }
    }

    func testNewPosesAreAcceptedByJev() async throws {
        for pose in ["playful", "cuddle", "shy", "stretch", "thinking", "excited"] {
            GatewayURLProtocol.handler = { _ in
                let body: [String: Any] = ["answers": ["pose": ["type": "choice", "choice": pose,
                    "probabilities": [pose: 0.98]]]]
                return (200, try JSONSerialization.data(withJSONObject: body))
            }
            let decision = try await api().choosePose(key: "test-key", history: [], companion: try TestCompanion.package())
            XCTAssertEqual(decision.pose, pose)
        }
    }

    func testJevReactionSendsFullPersonalityAndLastTenMixedInteractions() async throws {
        let package = try TestCompanion.package()
        var interactions = (0..<12).map {
            PetInteractionEvent(kind: "conversation", surface: "conversation", role: "user", text: "Turn \($0)")
        }
        interactions.append(.init(gesture: .tap, surface: "editor"))
        interactions.append(.init(gesture: .swipe(SIMD2(-1, 0)), surface: "desktop"))
        GatewayURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/evaluate")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            let body = try self.body(of: request)
            XCTAssertEqual(body["model"] as? String, GatewayAPI.poseModel)
            let state = try XCTUnwrap(body["state"] as? [String: Any])
            let personality = try XCTUnwrap(state["personality"] as? [String: String])
            XCTAssertEqual(personality["description"], package.personality.description)
            XCTAssertEqual(personality["instructions"], package.personality.instructions)
            XCTAssertEqual(personality["voice"], package.personality.voice)
            let recent = try XCTUnwrap(state["interactions"] as? [[String: Any]])
            XCTAssertEqual(recent.count, 10)
            XCTAssertEqual(recent.first?["text"] as? String, "Turn 4")
            XCTAssertEqual(recent[8]["surface"] as? String, "editor")
            XCTAssertEqual(recent.last?["kind"] as? String, "swipe")
            XCTAssertEqual(recent.last?["surface"] as? String, "desktop")
            XCTAssertEqual(recent.last?["direction"] as? [Float], [-1, 0])
            let questions = try XCTUnwrap(body["questions"] as? [String: [String: Any]])
            XCTAssertEqual(questions["animation"]?["type"] as? String, "choice")
            XCTAssertEqual(Set((questions["animation"]?["criteria"] as? [String: String] ?? [:]).keys),
                Set(PetReactionAnimation.allCases.map(\.rawValue)))
            return (200, Data(#"{"answers":{"pose":{"type":"choice","choice":"sleepy","probabilities":{"sleepy":0.97}},"animation":{"type":"choice","choice":"still","probabilities":{"still":0.96}}}}"#.utf8))
        }
        let decision = try await api().chooseReaction(key: "test-key", interactions: interactions, companion: package)
        XCTAssertEqual(decision.pose, "sleepy")
        XCTAssertEqual(decision.animation, .still)
    }

    func testJevReactionRejectsUnknownAnimationAndUsesNeutralLowConfidenceFallback() async throws {
        let package = try TestCompanion.package()
        GatewayURLProtocol.handler = { _ in
            (200, Data(#"{"answers":{"pose":{"type":"choice","choice":"happy","probabilities":{"happy":0.9}},"animation":{"type":"choice","choice":"invented","probabilities":{"invented":1}}}}"#.utf8))
        }
        do { _ = try await api().chooseReaction(key: "test-key", interactions: [], companion: package); XCTFail("Unsupported animation must fail") }
        catch { XCTAssertTrue(error is GatewayError) }
        GatewayURLProtocol.handler = { _ in
            (200, Data(#"{"answers":{"pose":{"type":"choice","choice":"happy","probabilities":{"happy":0.2}},"animation":{"type":"choice","choice":"bounce","probabilities":{"bounce":0.9}}}}"#.utf8))
        }
        let decision = try await api().chooseReaction(key: "test-key", interactions: [], companion: package)
        XCTAssertEqual(decision.pose, package.manifest.defaultPose)
        XCTAssertEqual(decision.animation, .still)
    }

    @MainActor func testCompletedConversationTurnsSharePetGestureHistoryAcrossDisconnect() async throws {
        let memory = PetInteractionHistory()
        let client = LiveClient(interactionHistory: memory)
        client.companion = try TestCompanion.package()
        client.automaticallyChoosePoses = false
        memory.append(.init(gesture: .tap, surface: "desktop"))
        client.handleEvent(["type": "input-transcription-completed", "transcript": "Hello kitten"])
        client.handleEvent(["type": "audio-transcript-delta", "delta": "Hello friend"])
        client.handleEvent(["type": "response-done"])
        XCTAssertEqual(memory.events.map(\.kind), ["tap", "conversation", "conversation"])
        XCTAssertEqual(memory.events.map(\.role), ["user", "user", "assistant"])
        XCTAssertEqual(memory.events.last?.text, "Hello friend")
        client.disconnect()
        XCTAssertEqual(memory.events.count, 3, "Ending voice must preserve gesture context")
        client.companion = try TestCompanion.package()
        XCTAssertTrue(memory.events.isEmpty, "Replacing the companion resets its memory")
    }

    @MainActor func testGroundingSourcesAttachToTheirReplyAndRejectUnsafeLinks() async throws {
        GatewayURLProtocol.handler = { _ in (200, Data(#"{"token":"vcst_test-secret"}"#.utf8)) }
        let socket = FakeGatewaySocket()
        let client = LiveClient(api: api(), socketFactory: { _, _ in socket })
        client.companion = try TestCompanion.package()
        client.automaticallyChoosePoses = false
        let ready = expectation(description: "Search session ready")
        client.onReady = { ready.fulfill() }
        if client.companion == nil { client.companion = try TestCompanion.package() }
        await client.connect(key: "test-key")
        await fulfillment(of: [ready], timeout: 2)
        let metadata: [String: Any] = ["webSearchQueries": ["Hong Kong weather today"], "groundingChunks": [
            ["web": ["uri": "https://www.hko.gov.hk/en/index.html", "title": "Hong Kong Observatory"]],
            ["web": ["uri": "javascript:alert(1)", "title": "Unsafe"]],
            ["web": ["uri": "file:///etc/passwd", "title": "Local file"]]
        ]]
        let raw: [String: Any] = ["serverContent": ["groundingMetadata": metadata]]
        client.handleEvent(["type": "custom", "rawType": "serverContent", "raw": raw])
        client.handleEvent(["type": "audio-transcript-delta", "delta": "Today's weather."])
        // The same raw grounding can occur on several normalized audio events.
        client.handleEvent(["type": "audio-delta", "raw": raw])
        XCTAssertTrue(client.hasSearched)
        XCTAssertEqual(client.messages.last?.sources.count, 1)
        XCTAssertEqual(client.messages.last?.sources.first?.title, "Hong Kong Observatory")
        client.handleEvent(["type": "response-done", "raw": raw])
        client.handleEvent(["type": "audio-transcript-delta", "delta": "You're welcome!"])
        XCTAssertTrue(client.messages.last!.sources.isEmpty, "An unsearched reply must not inherit the previous sources")
        // Grounding arriving after transcript text must update that same line.
        client.handleEvent(["type": "custom", "rawType": "serverContent", "raw": raw])
        XCTAssertEqual(client.messages.last?.sources.count, 1)
        client.disconnect()
        XCTAssertFalse(client.hasSearched)
        XCTAssertEqual(client.messages.first?.sources.count, 1, "Disconnect retains visible citations")
    }

    @MainActor func testSettingsSaveReplaceRemoveAndFailedStorage() {
        let store = MemoryGatewayKeyStore()
        let settings = GatewaySettings(store: store)
        XCTAssertFalse(settings.hasKey)
        XCTAssertTrue(settings.save(" test-first-key\n"))
        XCTAssertTrue(settings.hasKey)
        XCTAssertEqual(try settings.key(), "test-first-key")
        XCTAssertTrue(settings.save("test-replacement-key"))
        XCTAssertEqual(try settings.key(), "test-replacement-key")
        store.failWrites = true
        XCTAssertFalse(settings.save("test-other-key"))
        XCTAssertEqual(store.value, "test-replacement-key")
        XCTAssertNotNil(settings.error)
        XCTAssertTrue(settings.remove())
        XCTAssertFalse(settings.hasKey)
        XCTAssertThrowsError(try settings.key())
        XCTAssertFalse(settings.save(""))
    }

    @MainActor func testDirectNativeLiveAudioTranscriptAndInterruption() async throws {
        GatewayURLProtocol.handler = { _ in (200, Data(#"{"token":"vcst_test-secret"}"#.utf8)) }
        let socket = FakeGatewaySocket()
        socket.sessionReadyEvent = "session-created"
        let client = LiveClient(api: api(), socketFactory: { url, protocols in
            XCTAssertEqual(url.host, "ai-gateway.vercel.sh")
            XCTAssertEqual(protocols.last, "ai-gateway-auth.vcst_test-secret")
            return socket
        })
        client.companion = try TestCompanion.package()
        client.automaticallyChoosePoses = false
        let ready = expectation(description: "Native session ready")
        client.onReady = { ready.fulfill() }
        if client.companion == nil { client.companion = try TestCompanion.package() }
        await client.connect(key: "test-key")
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(client.state, .connected)
        let config = try XCTUnwrap(socket.sent.first?["config"] as? [String: Any])
        XCTAssertEqual((config["inputAudioFormat"] as? [String: Any])?["rate"] as? Int, 16000)
        XCTAssertEqual((config["outputAudioFormat"] as? [String: Any])?["rate"] as? Int, 24000)
        XCTAssertNil(config["turnDetection"], "Gemini must use its default VAD to avoid Gateway rejecting setup")
        XCTAssertNil(config["providerOptions"], "Native Google tools are rejected by Gateway's realtime transform")
        let tools = try XCTUnwrap(config["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["type"] as? String, "function")
        XCTAssertEqual(tools.first?["name"] as? String, "web_search")
        let audio = expectation(description: "Audio played")
        client.onAudio = { bytes in XCTAssertEqual(bytes, Data([0, 0, 1, 0])); audio.fulfill() }
        let interrupted = expectation(description: "Playback interrupted")
        let responseFinished = expectation(description: "Response finished separately from playback")
        client.onResponseDone = { responseFinished.fulfill() }
        client.onInterruption = { interrupted.fulfill() }
        socket.feed(["type": "audio-delta", "delta": "AAABAA=="])
        socket.feed(["type": "input-transcription-completed", "transcript": "Hello"])
        socket.feed(["type": "audio-transcript-delta", "delta": "Hello there"])
        socket.feed(["type": "audio-transcript-done", "transcript": "Hello there!"])
        socket.feed(["type": "response-done"])
        socket.feed(["type": "speech-started"])
        await fulfillment(of: [audio, interrupted, responseFinished], timeout: 2)
        XCTAssertEqual(client.messages.map(\.text), ["Hello", "Hello there!"])
        client.sendAudio(Data([0, 0, 1, 0]))
        client.sendText("Wave")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(socket.sent.contains { $0["type"] as? String == "input-audio-append" })
        XCTAssertTrue(socket.sent.contains { $0["type"] as? String == "conversation-item-create" })
        XCTAssertFalse(socket.sent.contains { $0["type"] as? String == "response-create" })
        client.disconnect()
        XCTAssertEqual(client.state, .disconnected)
    }

    @MainActor func testMicrophonePacketsAreDroppedWhileReplyPlaysAndResumeAfterward() async throws {
        GatewayURLProtocol.handler = { _ in (200, Data(#"{"token":"vcst_test-secret"}"#.utf8)) }
        let socket = FakeGatewaySocket()
        let client = LiveClient(api: api(), socketFactory: { _, _ in socket })
        client.companion = try TestCompanion.package()
        client.automaticallyChoosePoses = false
        let ready = expectation(description: "Connected for microphone gating")
        client.onReady = { ready.fulfill() }
        if client.companion == nil { client.companion = try TestCompanion.package() }
        await client.connect(key: "test-key")
        await fulfillment(of: [ready], timeout: 2)

        var listening = true
        client.canSendAudio = { listening }
        let pcm = Data([0, 0, 1, 0])
        client.sendAudio(pcm)
        // A queued microphone packet must be checked again before transmission.
        listening = false
        client.sendAudio(pcm)
        client.sendText("Hello")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(socket.sent.contains { $0["type"] as? String == "input-audio-append" })
        XCTAssertTrue(socket.sent.contains { $0["type"] as? String == "conversation-item-create" })

        listening = true
        client.sendAudio(pcm)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(socket.sent.filter { $0["type"] as? String == "input-audio-append" }.count, 1)
        client.disconnect()
    }

    @MainActor func testWebSocketSetupRejectionIsNotReportedAsBadKeyOrCredits() async throws {
        GatewayURLProtocol.handler = { _ in (200, Data(#"{"token":"vcst_test-secret"}"#.utf8)) }
        let socket = FakeGatewaySocket()
        socket.closeCode = .policyViolation
        socket.closeReason = Data("WebSocket transform rejected frame".utf8)
        socket.receiveError = NSError(domain: NSPOSIXErrorDomain, code: 57)
        let client = LiveClient(api: api(), socketFactory: { _, _ in socket })
        var started = false
        let closed = expectation(description: "Rejected connection cleaned up")
        client.onDisconnect = { if started { closed.fulfill() } }
        client.onReady = { XCTFail("Rejected session must not start the microphone") }
        if client.companion == nil { client.companion = try TestCompanion.package() }
        await client.connect(key: "test-key")
        started = true
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertEqual(client.state, .disconnected)
        let message = try XCTUnwrap(client.error)
        XCTAssertTrue(message.contains("configuration"))
        XCTAssertFalse(message.contains("credits"))
        XCTAssertFalse(message.contains("test-secret"))
    }

    @MainActor func testWebSocketAuthenticationRejectionKeepsActionableErrorAndRedactsReason() async throws {
        GatewayURLProtocol.handler = { _ in (200, Data(#"{"token":"vcst_test-secret"}"#.utf8)) }
        let socket = FakeGatewaySocket()
        socket.response = HTTPURLResponse(url: GatewayAPI.realtimeURL(), statusCode: 401, httpVersion: nil, headerFields: nil)
        socket.closeReason = Data("sensitive-provider-details vcst_test-secret".utf8)
        socket.receiveError = URLError(.badServerResponse)
        let client = LiveClient(api: api(), socketFactory: { _, _ in socket })
        var started = false
        let closed = expectation(description: "Unauthorized connection cleaned up")
        client.onDisconnect = { if started { closed.fulfill() } }
        if client.companion == nil { client.companion = try TestCompanion.package() }
        await client.connect(key: "test-key")
        started = true
        await fulfillment(of: [closed], timeout: 2)
        let message = try XCTUnwrap(client.error)
        XCTAssertTrue(message.contains("Settings"))
        XCTAssertFalse(message.contains("sensitive-provider-details"))
        XCTAssertFalse(message.contains("test-secret"))
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        if let data = request.httpBody { return try JSONSerialization.jsonObject(with: data) as! [String: Any] }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}

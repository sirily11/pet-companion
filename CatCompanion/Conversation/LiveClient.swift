import Foundation
import Combine

struct ConversationLine: Identifiable {
    let id = UUID()
    let role: String
    var text: String
    var sources: [WebSource] = []
}

struct WebSource: Identifiable, Hashable {
    let url: URL
    let title: String
    var id: String { url.absoluteString }

    init?(urlString: String, title: String?) {
        guard urlString.count <= 4096, let url = URL(string: urlString),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        self.url = url
        let label = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = label.isEmpty ? host : String(label.prefix(200))
    }
}

@MainActor
protocol GatewaySocketTransport: AnyObject {
    var maximumMessageSize: Int { get set }
    var response: URLResponse? { get }
    var closeCode: URLSessionWebSocketTask.CloseCode { get }
    var closeReason: Data? { get }
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
}

extension URLSessionWebSocketTask: GatewaySocketTransport {}

@MainActor
final class LiveClient: ObservableObject {
    enum State: String { case disconnected, connecting, connected }
    @Published private(set) var state: State = .disconnected
    @Published private(set) var messages: [ConversationLine] = []
    @Published var error: String?
    @Published private(set) var poseSource = "Manual"
    @Published private(set) var poseConfidence: Double?
    @Published private(set) var hasSearched = false
    var automaticallyChoosePoses = true {
        didSet {
            if !automaticallyChoosePoses { poseTask?.cancel(); poseTask = nil; poseSource = "Manual"; poseRevision += 1 }
        }
    }
    var onAudio: ((Data) -> Void)?
    var canSendAudio: (() -> Bool)?
    var onResponseDone: (() -> Void)?
    var onTranscript: ((String) -> Void)?
    var onInterruption: (() -> Void)?
    var onPose: ((String) -> Void)?
    var companion: CompanionPackage? {
        didSet { disconnect(); interactionHistory.reset(); messages = []; error = nil }
    }
    var onReady: (() -> Void)?
    var onDisconnect: (() -> Void)?
    private let api: GatewayAPI
    private var socket: (any GatewaySocketTransport)?
    private let socketFactory: (URL, [String]) -> any GatewaySocketTransport
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var poseTask: Task<Void, Never>?
    private var searchTasks: [String: Task<Void, Never>] = [:]
    private var handledSearchCalls = Set<String>()
    private var sessionGeneration = UUID()
    private var assistantIndex: Int?
    private var timeout: Task<Void, Never>?
    private var activeKey = ""
    let interactionHistory: PetInteractionHistory
    private var outputTranscript = ""
    private var poseRevision = 0
    private var pendingAudioBytes = 0
    private var responseSources: [WebSource] = []

    init(api: GatewayAPI = GatewayAPI(), interactionHistory: PetInteractionHistory? = nil,
         socketFactory: ((URL, [String]) -> any GatewaySocketTransport)? = nil) {
        self.api = api
        self.interactionHistory = interactionHistory ?? PetInteractionHistory()
        self.socketFactory = socketFactory ?? { url, protocols in api.session.webSocketTask(with: url, protocols: protocols) }
    }

    func connect(key: String) async {
        disconnect()
        error = nil
        guard !key.isEmpty else { error = GatewayError.missingKey.localizedDescription; return }
        guard let companion else { error = "Import a pet companion before starting a conversation."; return }
        state = .connecting
        activeKey = key
        let token = sessionGeneration
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled, self.state == .connecting, self.sessionGeneration == token else { return }
            self.fail("The voice connection timed out. Check your key, model access, and network.")
        }
        do {
            let secret = try await api.createRealtimeToken(key: key)
            guard sessionGeneration == token, state == .connecting else { return }
            let task = socketFactory(GatewayAPI.realtimeURL(), GatewayAPI.realtimeProtocols(token: secret))
            task.maximumMessageSize = 512 * 1024
            socket = task
            task.resume()
            send(GatewayAPI.sessionEvent(companion: companion), duringSetup: true)
            receiveTask = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        guard let self, self.sessionGeneration == token else { return }
                        let data: Data
                        switch message {
                        case .data(let bytes): data = bytes
                        case .string(let string): data = Data(string.utf8)
                        @unknown default: continue
                        }
                        self.handle(data)
                    }
                } catch {
                    guard let self, self.sessionGeneration == token, !Task.isCancelled else { return }
                    self.fail(Self.connectionError(error, socket: task))
                }
            }
        } catch {
            guard sessionGeneration == token else { return }
            fail((error as? GatewayError)?.localizedDescription ?? Self.connectionError(error))
        }
    }

    func disconnect() {
        sessionGeneration = UUID()
        timeout?.cancel(); timeout = nil
        receiveTask?.cancel(); receiveTask = nil
        sendTask?.cancel(); sendTask = nil
        poseTask?.cancel(); poseTask = nil
        for task in searchTasks.values { task.cancel() }
        searchTasks = [:]; handledSearchCalls = []
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        state = .disconnected
        assistantIndex = nil
        poseSource = "Manual"; poseConfidence = nil
        activeKey = ""; outputTranscript = ""
        responseSources = []; hasSearched = false
        pendingAudioBytes = 0; poseRevision += 1
        onDisconnect?()
    }

    private func fail(_ message: String) { disconnect(); error = message }

    private static func connectionError(_ error: Error, socket: (any GatewaySocketTransport)? = nil) -> String {
        if let status = (socket?.response as? HTTPURLResponse)?.statusCode, status != 101 {
            return GatewayError.http(status).localizedDescription
        }
        // Match known reasons without exposing arbitrary provider payloads or credentials.
        if let reason = socket?.closeReason,
           String(data: reason, encoding: .utf8) == "WebSocket transform rejected frame" {
            return "AI Gateway rejected the Gemini session configuration. Please reconnect; if it persists, the app's Gemini configuration needs updating."
        }
        if socket?.closeCode == .policyViolation {
            return "AI Gateway rejected the Gemini Live session. Check model access and account limits, then reconnect."
        }
        if let network = error as? URLError {
            switch network.code {
            case .timedOut:
                return "The Gemini Live connection timed out. Check your network or proxy, then reconnect."
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost:
                return "Could not connect to Gemini Live. Check your network or proxy, then reconnect."
            default: break
            }
        }
        return "The Gemini Live connection closed unexpectedly. Check your network or proxy, then reconnect."
    }

    func sendAudio(_ data: Data) {
        guard state == .connected, canSendAudio?() != false else { return }
        guard pendingAudioBytes + data.count < 16_000 * 2 * 3 else {
            fail("The connection cannot keep up with the microphone. Please reconnect."); return
        }
        send(["type": "input-audio-append", "audio": data.base64EncodedString()], audioBytes: data.count)
    }
    func clearInput() { send(["type": "input-audio-clear"]) }
    func sendText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard state == .connected, !trimmed.isEmpty else { return }
        let limited = String(trimmed.prefix(4000))
        messages.append(.init(role: "user", text: limited))
        addHistory(role: "user", text: limited)
        send(["type": "conversation-item-create", "item": ["type": "text-message", "role": "user", "text": limited]])
        // Gemini responds to conversation-item-create; no duplicate response-create.
    }

    private func send(_ value: [String: Any], duringSetup: Bool = false, audioBytes: Int = 0) {
        guard (state == .connected || duringSetup), let socket,
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else { return }
        let previous = sendTask
        let token = sessionGeneration
        pendingAudioBytes += audioBytes
        sendTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, self?.sessionGeneration == token else { return }
            if audioBytes > 0, self?.canSendAudio?() == false {
                self?.pendingAudioBytes -= audioBytes
                return
            }
            do {
                try await socket.send(.string(string))
                self?.pendingAudioBytes -= audioBytes
            } catch {
                guard self?.sessionGeneration == token else { return }
                self?.fail(Self.connectionError(error, socket: socket))
            }
        }
    }

    private func handle(_ data: Data) {
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { return }
        let events = (raw as? [[String: Any]]) ?? (raw as? [String: Any]).map { [$0] } ?? []
        for event in events {
            guard state != .disconnected else { return }
            handleEvent(event)
        }
    }

    // Gateway's realtime codec is an identity mapping over these normalized SDK
    // events. No Node runtime or provider-specific Gemini wire codec is needed.
    func handleEvent(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        captureGrounding(event)
        switch type {
        case "session-created", "session-updated":
            guard state == .connecting else { return }
            timeout?.cancel(); timeout = nil
            state = .connected
            onReady?()
        case "audio-delta":
            if let encoded = event["delta"] as? String, let bytes = Data(base64Encoded: encoded) { onAudio?(bytes) }
        case "audio-transcript-delta":
            guard let text = event["delta"] as? String else { return }
            outputTranscript = String((outputTranscript + text).prefix(8000))
            if let index = assistantIndex, messages.indices.contains(index) { messages[index].text = outputTranscript }
            else { messages.append(.init(role: "assistant", text: outputTranscript, sources: responseSources)); assistantIndex = messages.count - 1 }
            onTranscript?(outputTranscript)
        case "audio-transcript-done":
            if let text = event["transcript"] as? String, !text.isEmpty {
                outputTranscript = String(text.prefix(8000))
                if let index = assistantIndex, messages.indices.contains(index) { messages[index].text = outputTranscript }
                else { messages.append(.init(role: "assistant", text: outputTranscript, sources: responseSources)); assistantIndex = messages.count - 1 }
                onTranscript?(outputTranscript)
            }
        case "input-transcription-completed":
            if let text = event["transcript"] as? String, !text.isEmpty {
                messages.append(.init(role: "user", text: String(text.prefix(4000))))
                addHistory(role: "user", text: text)
            }
        case "response-done":
            if !outputTranscript.isEmpty { addHistory(role: "assistant", text: outputTranscript) }
            outputTranscript = ""; assistantIndex = nil; responseSources = []
            onResponseDone?()
        case "speech-started": onInterruption?(); outputTranscript = ""; assistantIndex = nil; responseSources = []
        case "function-call-arguments-done": handleSearchCall(event)
        case "error":
            // Do not echo arbitrary provider text that might contain request details.
            fail("Gemini Live reported an error. Check your Gateway key, credits, and model access in Settings.")
        default: break
        }
        if messages.count > 100 {
            let count = messages.count - 100
            messages.removeFirst(count)
            assistantIndex = assistantIndex.map { $0 - count }
        }
    }

    private func handleSearchCall(_ event: [String: Any]) {
        guard state == .connected, event["name"] as? String == "web_search",
              let callID = event["callId"] as? String, !callID.isEmpty, callID.count <= 200,
              !handledSearchCalls.contains(callID) else { return }
        handledSearchCalls.insert(callID)
        guard handledSearchCalls.count <= 64, searchTasks.count < 3,
              let arguments = event["arguments"] as? String, arguments.utf8.count <= 8000,
              let object = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
              let query = object["query"] as? String,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sendSearchOutput(callID: callID, result: ["error": "Search is unavailable for this request. Ask for a concise search query."])
            return
        }
        let generation = sessionGeneration
        let key = activeKey
        searchTasks[callID] = Task { [weak self] in
            guard let self else { return }
            defer { if self.sessionGeneration == generation { self.searchTasks[callID] = nil } }
            do {
                let result = try await self.api.searchWeb(key: key, query: query)
                guard !Task.isCancelled, self.sessionGeneration == generation else { return }
                self.hasSearched = true
                for source in result.sources where !self.responseSources.contains(source) && self.responseSources.count < 12 {
                    self.responseSources.append(source)
                }
                if let index = self.assistantIndex, self.messages.indices.contains(index) {
                    self.messages[index].sources = self.responseSources
                }
                self.sendSearchOutput(callID: callID, result: ["text": result.text,
                    "sources": result.sources.map { ["url": $0.url.absoluteString, "title": $0.title] }])
            } catch {
                guard !Task.isCancelled, self.sessionGeneration == generation else { return }
                self.sendSearchOutput(callID: callID, result: ["error": "Web search is unavailable. Tell the user you could not verify current information."])
            }
        }
    }

    private func sendSearchOutput(callID: String, result: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: result) else { return }
        send(["type": "conversation-item-create", "item": ["type": "function-call-output",
            "callId": callID, "name": "web_search", "output": String(decoding: data, as: UTF8.self)]])
    }

    private func captureGrounding(_ event: [String: Any]) {
        // Gateway preserves Gemini's wire payload on every normalized event,
        // including audio events. Grounding can arrive before or after text.
        let raw = event["raw"] as? [String: Any]
        let content = raw?["serverContent"] as? [String: Any]
        guard let metadata = (content?["groundingMetadata"] ?? raw?["groundingMetadata"] ?? event["groundingMetadata"]) as? [String: Any] else { return }
        if let queries = metadata["webSearchQueries"] as? [String], !queries.isEmpty { hasSearched = true }
        for chunk in (metadata["groundingChunks"] as? [[String: Any]] ?? []).prefix(20) {
            guard let web = chunk["web"] as? [String: Any], let uri = web["uri"] as? String,
                  let source = WebSource(urlString: uri, title: web["title"] as? String),
                  !responseSources.contains(where: { $0.id == source.id }), responseSources.count < 12 else { continue }
            responseSources.append(source)
            hasSearched = true
        }
        if let index = assistantIndex, messages.indices.contains(index) { messages[index].sources = responseSources }
    }

    private func addHistory(role: String, text: String) {
        interactionHistory.append(.init(kind: "conversation", surface: "conversation", role: role, text: text))
        requestPose()
    }

    private func requestPose() {
        guard automaticallyChoosePoses, state == .connected, !activeKey.isEmpty, let companion else { return }
        poseRevision += 1
        guard poseTask == nil else { return }
        let generation = sessionGeneration
        poseTask = Task { [weak self] in
            guard let self else { return }
            var handled = -1
            while !Task.isCancelled, self.sessionGeneration == generation, handled != self.poseRevision {
                let revision = self.poseRevision
                let interactionRevision = self.interactionHistory.revision
                handled = revision
                do {
                    let result = try await self.api.choosePose(key: self.activeKey, interactions: self.interactionHistory.events, companion: companion)
                    guard !Task.isCancelled, self.sessionGeneration == generation else { return }
                    if self.automaticallyChoosePoses, revision == self.poseRevision,
                       interactionRevision == self.interactionHistory.revision {
                        self.poseSource = "Jev"; self.poseConfidence = result.confidence; self.onPose?(result.pose)
                    }
                } catch {
                    guard !Task.isCancelled, self.sessionGeneration == generation else { return }
                    if revision == self.poseRevision, interactionRevision == self.interactionHistory.revision {
                        self.error = "Jev could not choose a pose. Manual poses still work."
                    }
                }
            }
            if self.sessionGeneration == generation { self.poseTask = nil }
        }
    }
}

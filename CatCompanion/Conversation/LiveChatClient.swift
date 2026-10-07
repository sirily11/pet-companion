import Foundation

struct LiveAudioFormat: Equatable, Sendable {
    let inputSampleRate: Int
    let outputSampleRate: Int
}

struct LiveChatConfiguration {
    let provider: LiveChatProvider
    let model: String
    let companion: CompanionPackage
    let profile: ConversationProfile
    var audioFormat: LiveAudioFormat { .init(inputSampleRate: provider.inputSampleRate, outputSampleRate: 24_000) }

    var sessionEvent: [String: Any] {
        var config: [String: Any] = [
            "instructions": profile.capabilities.instructions,
            "voice": provider == .gemini ? companion.personality.voice : "alloy",
            "outputModalities": ["audio"],
            "inputAudioFormat": ["type": "audio/pcm", "rate": audioFormat.inputSampleRate],
            "outputAudioFormat": ["type": "audio/pcm", "rate": audioFormat.outputSampleRate],
            "inputAudioTranscription": [:], "outputAudioTranscription": [:],
            "tools": [profile.capabilities.search.gatewayDefinition]
        ]
        if provider == .gemini {
            var options: [String: Any] = ["defaultToolBehavior": "BLOCKING"]
            if model.contains("extended-thinking") { options["thinkingConfig"] = ["thinkingLevel": "LOW"] }
            config["providerOptions"] = ["google": options]
            // Gemini must use its default VAD: Gateway rejects an override.
        } else {
            config["turnDetection"] = ["type": "server-vad"]
        }
        return ["type": "session-update", "config": config]
    }
}

enum LiveChatEvent {
    case ready, responseDone, interrupted
    case audio(Data), transcriptDelta(String), transcriptDone(String), userTranscript(String)
    case toolCall(id: String, name: String, arguments: String)
    case toolsCancelled([String])
    case grounding([WebSource], searched: Bool)
    case failed(String)

    static func decode(_ event: [String: Any]) -> [LiveChatEvent] {
        var events: [LiveChatEvent] = []
        let raw = event["raw"] as? [String: Any]
        let content = raw?["serverContent"] as? [String: Any]
        if let metadata = (content?["groundingMetadata"] ?? raw?["groundingMetadata"] ?? event["groundingMetadata"]) as? [String: Any] {
            let sources = (metadata["groundingChunks"] as? [[String: Any]] ?? []).prefix(20).compactMap { chunk -> WebSource? in
                guard let web = chunk["web"] as? [String: Any], let uri = web["uri"] as? String else { return nil }
                return WebSource(urlString: uri, title: web["title"] as? String)
            }
            events.append(.grounding(sources, searched: !(metadata["webSearchQueries"] as? [String] ?? []).isEmpty))
        }
        switch event["type"] as? String {
        case "session-created", "session-updated": events.append(.ready)
        case "audio-delta":
            if let value = event["delta"] as? String, let bytes = Data(base64Encoded: value) { events.append(.audio(bytes)) }
        case "audio-transcript-delta":
            if let value = event["delta"] as? String { events.append(.transcriptDelta(value)) }
        case "audio-transcript-done":
            if let value = event["transcript"] as? String { events.append(.transcriptDone(value)) }
        case "input-transcription-completed":
            if let value = event["transcript"] as? String { events.append(.userTranscript(value)) }
        case "response-done": events.append(.responseDone)
        case "speech-started": events.append(.interrupted)
        case "function-call-arguments-done":
            if let id = event["callId"] as? String, let name = event["name"] as? String {
                events.append(.toolCall(id: id, name: name, arguments: event["arguments"] as? String ?? ""))
            }
        case "custom":
            if event["rawType"] as? String == "toolCallCancellation",
               let cancellation = raw?["toolCallCancellation"] as? [String: Any], let ids = cancellation["ids"] as? [String] {
                events.append(.toolsCancelled(Array(ids.prefix(64))))
            }
        case "error": events.append(.failed("The voice model reported an error. Check your Gateway key, credits, and model access in Settings."))
        default: break
        }
        return events
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
protocol LiveChatClient: AnyObject {
    var onEvent: ((LiveChatEvent) -> Void)? { get set }
    var canSendAudio: (() -> Bool)? { get set }
    func connect(configuration: LiveChatConfiguration, key: String) async throws
    func disconnect()
    func sendAudio(_ data: Data)
    func clearInput()
    func sendText(_ text: String)
    func sendToolResult(id: String, name: String, output: String)
    func cancelTool(_ id: String)
}

/// Shared Gateway framing, auth, ordering and backpressure. Subclasses own
/// provider continuation behavior; the observable session owns app state.
@MainActor
class GatewayLiveChatClient: LiveChatClient {
    var onEvent: ((LiveChatEvent) -> Void)?
    var canSendAudio: (() -> Bool)?
    private let api: GatewayAPI
    private let socketFactory: (URL, [String]) -> any GatewaySocketTransport
    private var socket: (any GatewaySocketTransport)?
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var generation = UUID()
    private var pendingAudioBytes = 0
    private var sampleRate = 16_000
    private var cancelledTools = Set<String>()
    var explicitlyContinues: Bool { false }

    init(api: GatewayAPI = GatewayAPI(), socketFactory: ((URL, [String]) -> any GatewaySocketTransport)? = nil) {
        self.api = api
        self.socketFactory = socketFactory ?? { api.session.webSocketTask(with: $0, protocols: $1) }
    }

    func connect(configuration: LiveChatConfiguration, key: String) async throws {
        disconnect()
        sampleRate = configuration.audioFormat.inputSampleRate
        let revision = generation
        let secret = try await api.createRealtimeToken(key: key, model: configuration.model)
        guard generation == revision, !Task.isCancelled else { return }
        let task = socketFactory(GatewayAPI.realtimeURL(model: configuration.model), GatewayAPI.realtimeProtocols(token: secret))
        task.maximumMessageSize = 512 * 1024
        socket = task
        task.resume()
        send(configuration.sessionEvent)
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    guard let self, self.generation == revision else { return }
                    let bytes: Data
                    switch message {
                    case .data(let value): bytes = value
                    case .string(let value): bytes = Data(value.utf8)
                    @unknown default: continue
                    }
                    guard let raw = try? JSONSerialization.jsonObject(with: bytes) else { continue }
                    let values = (raw as? [[String: Any]]) ?? (raw as? [String: Any]).map { [$0] } ?? []
                    for value in values {
                        for event in LiveChatEvent.decode(value) {
                            guard self.generation == revision else { return }
                            self.onEvent?(event)
                        }
                    }
                }
            } catch {
                guard let self, !Task.isCancelled, self.generation == revision else { return }
                self.onEvent?(.failed(Self.connectionError(error, socket: task)))
            }
        }
    }

    func disconnect() {
        generation = UUID()
        receiveTask?.cancel(); receiveTask = nil
        sendTask?.cancel(); sendTask = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        pendingAudioBytes = 0; cancelledTools = []
    }

    func sendAudio(_ data: Data) {
        guard canSendAudio?() != false else { return }
        guard pendingAudioBytes + data.count < sampleRate * 2 * 3 else {
            onEvent?(.failed("The connection cannot keep up with the microphone. Please reconnect.")); return
        }
        send(["type": "input-audio-append", "audio": data.base64EncodedString()], audioBytes: data.count)
    }
    func clearInput() { send(["type": "input-audio-clear"]) }
    func sendText(_ text: String) {
        send(["type": "conversation-item-create", "item": ["type": "text-message", "role": "user", "text": text]])
        if explicitlyContinues { send(["type": "response-create"]) }
    }
    func sendToolResult(id: String, name: String, output: String) {
        send(["type": "conversation-item-create", "item": ["type": "function-call-output",
              "callId": id, "name": name, "output": output]], toolID: id)
        if explicitlyContinues { send(["type": "response-create"], toolID: id) }
    }
    func cancelTool(_ id: String) { cancelledTools.insert(id) }

    private func send(_ value: [String: Any], audioBytes: Int = 0, toolID: String? = nil) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        let previous = sendTask, revision = generation
        pendingAudioBytes += audioBytes
        sendTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.generation == revision else { return }
            defer { if self.generation == revision { self.pendingAudioBytes -= audioBytes } }
            if let toolID, self.cancelledTools.contains(toolID) { return }
            if audioBytes > 0, self.canSendAudio?() == false { return }
            do { try await socket.send(.string(String(decoding: data, as: UTF8.self))) }
            catch { if self.generation == revision { self.onEvent?(.failed(Self.connectionError(error, socket: socket))) } }
        }
    }

    private static func connectionError(_ error: Error, socket: any GatewaySocketTransport) -> String {
        if let status = (socket.response as? HTTPURLResponse)?.statusCode, status != 101 { return GatewayError.http(status).localizedDescription }
        if socket.closeReason == Data("WebSocket transform rejected frame".utf8) {
            return "AI Gateway rejected the voice session configuration. Please reconnect; if it persists, the app’s configuration needs updating."
        }
        if socket.closeCode == .policyViolation { return "AI Gateway rejected the voice session. Check model access and account limits, then reconnect." }
        if (error as? URLError)?.code == .timedOut { return "The voice connection timed out. Check your network or proxy, then reconnect." }
        return "The voice connection closed unexpectedly. Check your network or proxy, then reconnect."
    }
}

@MainActor final class GeminiLiveClient: GatewayLiveChatClient {}
@MainActor final class GPTRealtimeClient: GatewayLiveChatClient {
    override var explicitlyContinues: Bool { true }
}

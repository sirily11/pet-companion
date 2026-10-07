import Foundation
import Combine

struct ConversationLine: Identifiable {
    let id = UUID()
    let role: String
    var text: String
    var sources: [WebSource] = []
    var toolCall: ConversationToolCall? = nil
}

struct ConversationToolCall: Equatable {
    enum Status: String {
        case running = "Running"
        case completed = "Completed"
        case failed = "Failed"
        case cancelled = "Cancelled"

        var symbol: String {
            switch self {
            case .running: "magnifyingglass"
            case .completed: "checkmark.circle"
            case .failed: "exclamationmark.circle"
            case .cancelled: "xmark.circle"
            }
        }
    }

    let callID: String
    let name: String
    let query: String?
    var status: Status = .running
    var result: String? = nil
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
final class ConversationSession: ObservableObject {
    enum State: String { case disconnected, connecting, connected }
    @Published private(set) var state: State = .disconnected
    @Published private(set) var messages: [ConversationLine] = []
    @Published var error: String?
    @Published private(set) var poseSource = "Manual"
    @Published private(set) var poseConfidence: Double?
    @Published private(set) var hasSearched = false
    @Published private(set) var isSearching = false
    @Published private(set) var visibleToolCalls: [ConversationToolCall] = []
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
    @Published var provider: LiveChatProvider = .gemini
    @Published var model = LiveChatProvider.gemini.defaultModel
    var audioFormat: LiveAudioFormat { .init(inputSampleRate: provider.inputSampleRate, outputSampleRate: 24_000) }
    var choosePose: (([PetInteractionEvent], CompanionPackage) async throws -> PoseDecision)?
    var decisionSource: (() -> String)?
    private var client: (any LiveChatClient)?
    private var profile: ConversationProfile?
    private let clientFactory: (LiveChatProvider) -> any LiveChatClient
    private var poseTask: Task<Void, Never>?
    private var searchTasks: [String: Task<Void, Never>] = [:]
    private var toolCallExpiryTasks: [String: Task<Void, Never>] = [:]
    private var handledSearchCalls = Set<String>()
    private var cancelledSearchCalls = Set<String>()
    private var sessionGeneration = UUID()
    private var assistantIndex: Int?
    private var timeout: Task<Void, Never>?
    private var activeKey = ""
    let interactionHistory: PetInteractionHistory
    private var outputTranscript = ""
    private var poseRevision = 0
    private var responseSources: [WebSource] = []

    init(api: GatewayAPI = GatewayAPI(), interactionHistory: PetInteractionHistory? = nil,
         socketFactory: ((URL, [String]) -> any GatewaySocketTransport)? = nil) {
        self.api = api
        self.interactionHistory = interactionHistory ?? PetInteractionHistory()
        self.clientFactory = { provider in
            if provider == .gemini { return GeminiLiveClient(api: api, socketFactory: socketFactory) }
            return GPTRealtimeClient(api: api, socketFactory: socketFactory)
        }
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
        let adapter = clientFactory(provider)
        client = adapter
        adapter.canSendAudio = { [weak self] in self?.canSendAudio?() != false }
        adapter.onEvent = { [weak self] event in
            guard let self, self.sessionGeneration == token else { return }
            self.handle(event)
        }
        let profile = ConversationProfile(companion: companion, api: api, key: key)
        self.profile = profile
        do {
            try await adapter.connect(configuration: .init(provider: provider, model: model, companion: companion, profile: profile), key: key)
        } catch {
            guard sessionGeneration == token else { return }
            fail((error as? GatewayError)?.localizedDescription ?? "Could not connect to the voice model. Check your network and model access.")
        }
    }

    func disconnect() {
        sessionGeneration = UUID()
        timeout?.cancel(); timeout = nil
        poseTask?.cancel(); poseTask = nil
        for task in searchTasks.values { task.cancel() }
        for task in toolCallExpiryTasks.values { task.cancel() }
        toolCallExpiryTasks = [:]
        visibleToolCalls = []
        for index in messages.indices where messages[index].toolCall?.status == .running {
            messages[index].toolCall?.status = .cancelled
            messages[index].toolCall?.result = "The conversation ended before the tool finished."
        }
        searchTasks = [:]; handledSearchCalls = []; cancelledSearchCalls = []
        client?.disconnect(); client = nil
        profile = nil
        state = .disconnected
        assistantIndex = nil
        poseSource = "Manual"; poseConfidence = nil
        activeKey = ""; outputTranscript = ""
        responseSources = []; hasSearched = false; isSearching = false
        poseRevision += 1
        onDisconnect?()
    }

    private func fail(_ message: String) { disconnect(); error = message }

    func sendAudio(_ data: Data) {
        guard state == .connected, canSendAudio?() != false else { return }
        client?.sendAudio(data)
    }
    func clearInput() { client?.clearInput() }
    func sendText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard state == .connected, !trimmed.isEmpty else { return }
        let limited = String(trimmed.prefix(4000))
        messages.append(.init(role: "user", text: limited))
        addHistory(role: "user", text: limited)
        client?.sendText(limited)
    }

    // Kept as a small normalized-event seam for deterministic transport tests.
    func handleEvent(_ value: [String: Any]) { LiveChatEvent.decode(value).forEach(handle) }

    private func handle(_ event: LiveChatEvent) {
        switch event {
        case .ready:
            guard state == .connecting else { return }
            timeout?.cancel(); timeout = nil
            state = .connected
            onReady?()
        case .audio(let bytes): onAudio?(bytes)
        case .transcriptDelta(let text): updateTranscript(String((outputTranscript + text).prefix(8000)))
        case .transcriptDone(let text): if !text.isEmpty { updateTranscript(String(text.prefix(8000))) }
        case .userTranscript(let text):
            if !text.isEmpty {
                messages.append(.init(role: "user", text: String(text.prefix(4000))))
                addHistory(role: "user", text: text)
            }
        case .responseDone:
            if !outputTranscript.isEmpty { addHistory(role: "assistant", text: outputTranscript) }
            outputTranscript = ""; assistantIndex = nil; responseSources = []
            onResponseDone?()
        case .interrupted:
            onInterruption?(); outputTranscript = ""; assistantIndex = nil; responseSources = []
        case .toolCall(let id, let name, let arguments):
            guard name == "web_search" else {
                client?.sendToolResult(id: id, name: name, output: "{\"error\":\"Unknown tool. Only web_search is available.\"}")
                return
            }
            handleSearchCall(["callId": id, "name": name, "arguments": arguments])
        case .toolsCancelled(let ids): cancelSearchCalls(ids)
        case .grounding(let sources, let searched):
            if searched || !sources.isEmpty { hasSearched = true }
            for source in sources where !responseSources.contains(where: { $0.id == source.id }) && responseSources.count < 12 {
                responseSources.append(source)
            }
            if let index = assistantIndex, messages.indices.contains(index) { messages[index].sources = responseSources }
        case .failed(let message): fail(message)
        }
        if messages.count > 100 {
            let count = messages.count - 100
            messages.removeFirst(count)
            assistantIndex = assistantIndex.map { $0 - count }
        }
    }

    private func updateTranscript(_ text: String) {
        outputTranscript = text
        if let index = assistantIndex, messages.indices.contains(index) { messages[index].text = text }
        else { messages.append(.init(role: "assistant", text: text, sources: responseSources)); assistantIndex = messages.count - 1 }
        onTranscript?(text)
    }

    private func handleSearchCall(_ event: [String: Any]) {
        guard state == .connected, event["name"] as? String == "web_search",
              let callID = event["callId"] as? String, !callID.isEmpty, callID.count <= 200,
              !handledSearchCalls.contains(callID) else { return }
        handledSearchCalls.insert(callID)
        let arguments = event["arguments"] as? String
        let object: [String: Any]?
        if let arguments, arguments.utf8.count <= 8000 {
            object = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
        } else { object = nil }
        let query = (object?["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let call = ConversationToolCall(callID: callID, name: "web_search",
                                       query: query.map { String($0.prefix(4000)) })
        messages.append(.init(role: "tool", text: "", toolCall: call))
        visibleToolCalls.append(call)
        guard handledSearchCalls.count <= 64, searchTasks.count < 3,
              let query, !query.isEmpty else {
            sendSearchOutput(callID: callID, result: ["error": "Search is unavailable for this request. Ask for a concise search query."])
            return
        }
        let generation = sessionGeneration
        guard let tool = profile?.capabilities.search else { return }
        searchTasks[callID] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.sessionGeneration == generation {
                    self.searchTasks[callID] = nil
                    self.isSearching = !self.searchTasks.isEmpty
                }
            }
            do {
                let result = try await tool.search(WebSearchArguments(query: query))
                guard !Task.isCancelled, self.sessionGeneration == generation else { return }
                self.hasSearched = true
                for source in result.sources where !self.responseSources.contains(where: { $0.id == source.id }) && self.responseSources.count < 12 {
                    self.responseSources.append(source)
                }
                if let index = self.assistantIndex, self.messages.indices.contains(index) {
                    self.messages[index].sources = self.responseSources
                }
                self.sendSearchOutput(callID: callID, result: ["text": result.text,
                    "sources": result.sources.map { ["url": $0.url.absoluteString, "title": $0.title] }],
                    sources: result.sources)
            } catch {
                guard !Task.isCancelled, self.sessionGeneration == generation else { return }
                self.sendSearchOutput(callID: callID, result: ["error": "Web search is unavailable. Tell the user you could not verify current information."])
            }
        }
        isSearching = true
    }

    private func cancelSearchCalls(_ callIDs: [String]) {
        for callID in callIDs.prefix(64) where handledSearchCalls.contains(callID) {
            cancelledSearchCalls.insert(callID)
            client?.cancelTool(callID)
            searchTasks.removeValue(forKey: callID)?.cancel()
            updateToolCall(callID: callID, status: .cancelled, result: "The tool call was cancelled.")
        }
        isSearching = !searchTasks.isEmpty
    }

    private func updateToolCall(callID: String, status: ConversationToolCall.Status,
                                result: String?, sources: [WebSource] = []) {
        if let index = messages.lastIndex(where: { $0.toolCall?.callID == callID }) {
            messages[index].toolCall?.status = status
            messages[index].toolCall?.result = result
            messages[index].sources = sources
        }
        guard let index = visibleToolCalls.firstIndex(where: { $0.callID == callID }) else { return }
        visibleToolCalls[index].status = status
        visibleToolCalls[index].result = result
        toolCallExpiryTasks.removeValue(forKey: callID)?.cancel()
        guard status != .running else { return }
        // Keep the outcome beside the pet's reply briefly, then remove only its bubble.
        let generation = sessionGeneration
        toolCallExpiryTasks[callID] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(6)) }
            catch { return }
            guard let self, !Task.isCancelled, self.sessionGeneration == generation else { return }
            self.visibleToolCalls.removeAll { $0.callID == callID }
            self.toolCallExpiryTasks[callID] = nil
        }
    }

    private func sendSearchOutput(callID: String, result: [String: Any], sources: [WebSource] = []) {
        let failure = result["error"] as? String
        updateToolCall(callID: callID, status: failure == nil ? .completed : .failed,
                       result: failure ?? result["text"] as? String, sources: sources)
        guard let data = try? JSONSerialization.data(withJSONObject: result) else { return }
        client?.sendToolResult(id: callID, name: "web_search", output: String(decoding: data, as: UTF8.self))
    }

    private func addHistory(role: String, text: String) {
        interactionHistory.append(.init(kind: "conversation", surface: "conversation", role: role, text: text))
        requestPose()
    }

    func cancelPoseSelection() {
        poseTask?.cancel(); poseTask = nil; poseRevision += 1
        poseSource = "Manual"; poseConfidence = nil
    }

    private func requestPose() {
        guard automaticallyChoosePoses, state == .connected, let companion else { return }
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
                    let result: PoseDecision
                    if let choosePose = self.choosePose { result = try await choosePose(self.interactionHistory.events, companion) }
                    else { result = try await self.api.choosePose(key: self.activeKey, interactions: self.interactionHistory.events, companion: companion) }
                    guard !Task.isCancelled, self.sessionGeneration == generation else { return }
                    if self.automaticallyChoosePoses, revision == self.poseRevision,
                       interactionRevision == self.interactionHistory.revision {
                        self.poseSource = self.decisionSource?() ?? "Jev (cloud)"; self.poseConfidence = result.confidence; self.onPose?(result.pose)
                    }
                } catch {
                    guard !Task.isCancelled, self.sessionGeneration == generation else { return }
                    if revision == self.poseRevision, interactionRevision == self.interactionHistory.revision {
                        self.error = error.localizedDescription
                    }
                }
            }
            if self.sessionGeneration == generation { self.poseTask = nil }
        }
    }
}

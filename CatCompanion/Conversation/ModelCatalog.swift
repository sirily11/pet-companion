import Foundation
import Combine

enum LiveChatProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case gemini, gpt
    var id: String { rawValue }
    var title: String { self == .gemini ? "Gemini (Google)" : "GPT (OpenAI)" }
    var defaultModel: String { self == .gemini ? "google/gemini-3.8-live" : "openai/gpt-realtime-2" }
    var inputSampleRate: Int { self == .gemini ? 16_000 : 24_000 }
    func supports(_ model: GatewayModel) -> Bool {
        guard model.type == "realtime", model.modalities?.input.contains("audio") == true,
              model.modalities?.output.contains("audio") == true else { return false }
        switch self {
        case .gemini: return model.id.hasPrefix("google/gemini-") && model.id.contains("-live")
        case .gpt: return model.id.hasPrefix("openai/gpt-realtime")
        }
    }
}

struct GatewayModel: Codable, Identifiable, Equatable, Sendable {
    struct Modalities: Codable, Equatable, Sendable { let input: [String]; let output: [String] }
    let id: String
    let name: String
    let type: String
    var modalities: Modalities?
    static let defaults = LiveChatProvider.allCases.map {
        GatewayModel(id: $0.defaultModel, name: $0 == .gemini ? "Gemini 3.8 Live" : "GPT Realtime 2",
                     type: "realtime", modalities: .init(input: ["audio", "text"], output: ["audio", "text"]))
    }
}

@MainActor
final class ModelCatalog: ObservableObject {
    @Published private(set) var models: [GatewayModel] = GatewayModel.defaults
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: String?
    private(set) var fetchedAt: Date?
    private let session: URLSession
    private let cacheURL: URL
    private let now: () -> Date
    static let lifetime: TimeInterval = 24 * 60 * 60
    private struct Cache: Codable { let fetchedAt: Date; let models: [GatewayModel] }
    private struct Response: Decodable { let data: [GatewayModel] }

    init(session: URLSession = .shared, cacheURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.session = session; self.now = now
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PetPaw/model-catalog.json")
        if let data = try? Data(contentsOf: self.cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data),
           !cache.models.isEmpty {
            models = cache.models; fetchedAt = cache.fetchedAt
        }
    }

    func models(for provider: LiveChatProvider) -> [GatewayModel] {
        models.filter(provider.supports).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func contains(_ id: String, provider: LiveChatProvider) -> Bool { models(for: provider).contains { $0.id == id } }

    func refresh(force: Bool = false) async {
        guard !isRefreshing, force || fetchedAt.map({ now().timeIntervalSince($0) >= Self.lifetime }) != false else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let request = URLRequest(url: URL(string: GatewayAPI.origin + "/v1/models")!, timeoutInterval: 20)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 8 * 1024 * 1024 else {
                throw GatewayError.invalidResponse
            }
            let available = try JSONDecoder().decode(Response.self, from: data).data
            guard !available.isEmpty else { throw GatewayError.invalidResponse }
            let cache = Cache(fetchedAt: now(), models: available)
            let bytes = try JSONEncoder().encode(cache)
            let destination = cacheURL
            try await Task.detached {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: destination, options: .atomic)
            }.value
            models = available; fetchedAt = cache.fetchedAt; error = nil
        } catch {
            self.error = "Couldn’t refresh models. The saved list is still available."
        }
    }
}

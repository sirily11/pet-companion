import Foundation
import Combine
import Security

protocol GatewayKeyStore {
    func containsKey() throws -> Bool
    func load() throws -> String?
    func save(_ key: String) throws
    func delete() throws
}

extension GatewayKeyStore {
    func containsKey() throws -> Bool { !(try load() ?? "").isEmpty }
}

struct KeychainGatewayKeyStore: GatewayKeyStore {
    private let service = "com.rxlab.CatCompanion.ai-gateway"
    private let account = "api-key"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func containsKey() throws -> Bool {
        // Checking saved status must not read the secret or prompt at launch.
        var request = query
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(request as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return true
    }
    func load() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else { return nil }
        return key
    }
    func save(_ key: String) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Could not access the saved Gateway key in Keychain (\(status)). Try again after unlocking your Mac." }
}

@MainActor
final class GatewaySettings: ObservableObject {
    @Published private(set) var hasKey = false
    @Published var error: String?
    @Published var provider: LiveChatProvider { didSet { defaults.set(provider.rawValue, forKey: "voiceProvider") } }
    @Published var decisionBackend: DecisionBackend { didSet { defaults.set(decisionBackend.rawValue, forKey: "decisionBackend") } }
    @Published private var modelSelections: [String: String] {
        didSet { defaults.set(modelSelections, forKey: "voiceModels") }
    }
    private let defaults: UserDefaults
    var selectedModel: String { model(for: provider) }
    func model(for provider: LiveChatProvider) -> String { modelSelections[provider.rawValue] ?? provider.defaultModel }
    func selectModel(_ model: String) { modelSelections[provider.rawValue] = model }
    private let store: GatewayKeyStore

    init(store: GatewayKeyStore = KeychainGatewayKeyStore(), defaults: UserDefaults = .standard) {
        self.store = store; self.defaults = defaults
        provider = LiveChatProvider(rawValue: defaults.string(forKey: "voiceProvider") ?? "") ?? .gemini
        decisionBackend = DecisionBackend(rawValue: defaults.string(forKey: "decisionBackend") ?? "") ?? .cloud
        modelSelections = defaults.dictionary(forKey: "voiceModels") as? [String: String] ?? [:]
        do { hasKey = try store.containsKey() }
        catch { self.error = error.localizedDescription }
    }

    func key() throws -> String {
        guard let key = try store.load(), !key.isEmpty else { throw GatewayError.missingKey }
        return key
    }

    func save(_ value: String) -> Bool {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            error = "Enter a valid Gateway key without spaces."
            return false
        }
        do { try store.save(key); hasKey = true; error = nil; return true }
        catch { self.error = error.localizedDescription; return false }
    }

    func remove() -> Bool {
        do { try store.delete(); hasKey = false; error = nil; return true }
        catch { self.error = error.localizedDescription; return false }
    }
}

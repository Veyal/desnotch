import Foundation
import Security

/// Where the provider's API key lives. Only the Keychain implementation ships; the key is never
/// written to UserDefaults, the audit log, Settings export, or anywhere else.
protocol VoiceAIKeyStoring: Sendable {
    /// The stored key, or nil. Reading the secret can show a Keychain prompt, so callers read it
    /// only right before a request.
    func readKey() -> String?
    /// Whether a key is stored, without reading the secret.
    func hasKey() -> Bool
    @discardableResult
    func saveKey(_ key: String) -> Bool
    @discardableResult
    func deleteKey() -> Bool
}

enum VoiceAIKeyFormat {
    static let maxLength = 512

    /// Trimmed key, or nil when it is empty, too long, or contains whitespace or control
    /// characters (a pasted key with a newline would otherwise corrupt the header).
    static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return nil }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard trimmed.unicodeScalars.allSatisfy({ $0.isASCII && !forbidden.contains($0) }) else { return nil }
        return trimmed
    }
}

/// Generic-password item in the login Keychain. The OpenAI-compatible key uses service
/// `com.desnotch.app.voice-ai`, the Anthropic key its own service
/// `com.desnotch.app.voice-ai.anthropic`, so neither provider can ever be sent the other's key.
/// Accessible only while the Mac is unlocked, and never synced to other devices.
struct KeychainVoiceAIKeyStore: VoiceAIKeyStoring {
    static let service = "com.desnotch.app.voice-ai"
    static let anthropicService = "com.desnotch.app.voice-ai.anthropic"
    static let account = "api-key"

    let service: String
    let account: String

    init(service: String = KeychainVoiceAIKeyStore.service, account: String = KeychainVoiceAIKeyStore.account) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func readKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8)
        else { return nil }
        return VoiceAIKeyFormat.normalized(key)
    }

    func hasKey() -> Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    func saveKey(_ key: String) -> Bool {
        guard let normalized = VoiceAIKeyFormat.normalized(key) else { return false }
        let data = Data(normalized.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrLabel as String] = service == Self.anthropicService
            ? "desnotch voice Anthropic key"
            : "desnotch voice AI provider key"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func deleteKey() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

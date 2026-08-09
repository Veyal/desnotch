import Foundation
import Security

public protocol SpeechAPIKeyStoring {
    func load() -> String?
    func save(_ key: String) throws
    func remove() throws
}

public enum SpeechKeychainError: Error { case unexpectedStatus(OSStatus) }

public final class SpeechKeychainStore: SpeechAPIKeyStoring {
    private let service: String
    public init(service: String = "com.desnotch.openai") { self.service = service }
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api-key"] }
    public func load() -> String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?; guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    public func save(_ key: String) throws {
        let data = Data(key.utf8); let status = SecItemAdd(query.merging([kSecValueData as String: data]) { $1 } as CFDictionary, nil)
        if status == errSecDuplicateItem { let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary); if update != errSecSuccess { throw SpeechKeychainError.unexpectedStatus(update) } }
        else if status != errSecSuccess { throw SpeechKeychainError.unexpectedStatus(status) }
    }
    public func remove() throws { let status = SecItemDelete(query as CFDictionary); if status != errSecSuccess && status != errSecItemNotFound { throw SpeechKeychainError.unexpectedStatus(status) } }
}

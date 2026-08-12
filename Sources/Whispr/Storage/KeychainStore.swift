import Foundation
import Security

/// Stores Deepgram and LLM API keys as independent generic passwords in macOS Keychain.
enum KeychainStore {

    private static let service = "com.whispr.app"
    private static let deepgramAccount = "deepgram-api-key"
    private static let polishAccount = "polish-api-key"

    static func saveAPIKey(_ key: String) throws {
        try save(key, account: deepgramAccount)
    }

    static func savePolishAPIKey(_ key: String) throws {
        try save(key, account: polishAccount)
    }

    private static func save(_ key: String, account: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let attributes: [String: Any] = [kSecValueData as String: data]
            try check(SecItemUpdate(query as CFDictionary, attributes as CFDictionary))
        } else if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    static func loadAPIKey() -> String? {
        load(account: deepgramAccount)
    }

    static func loadPolishAPIKey() -> String? {
        load(account: polishAccount)
    }

    private static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteAPIKey() {
        delete(account: deepgramAccount)
    }

    static func deletePolishAPIKey() {
        delete(account: polishAccount)
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    enum KeychainError: LocalizedError {
        case unhandled(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unhandled(let status):
                if let message = SecCopyErrorMessageString(status, nil) as String? {
                    return "Keychain error: \(message)"
                }
                return "Keychain error (status \(status))"
            }
        }
    }
}

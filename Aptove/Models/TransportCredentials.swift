import Foundation
import Security

/// Credentials for a single transport endpoint, stored in Keychain keyed by endpoint ID.
struct TransportCredentials: Codable {
    let authToken: String?
    let certFingerprint: String?
    let clientId: String?
    let clientSecret: String?
}

// MARK: - Keychain Storage

enum TransportCredentialManager {
    private static let service = "com.aptove.transportcredentials"

    enum Error: LocalizedError {
        case saveFailed(OSStatus)
        case retrieveFailed(OSStatus)
        var errorDescription: String? {
            switch self {
            case .saveFailed(let s): return "Failed to save transport credentials (OSStatus \(s))"
            case .retrieveFailed(let s): return "Failed to retrieve transport credentials (OSStatus \(s))"
            }
        }
    }

    static func save(_ credentials: TransportCredentials, for endpointId: String) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: endpointId,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw Error.saveFailed(status)
        }
    }

    static func retrieve(for endpointId: String) throws -> TransportCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: endpointId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw Error.retrieveFailed(status)
        }
        return try JSONDecoder().decode(TransportCredentials.self, from: data)
    }

    static func delete(for endpointId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: endpointId
        ]
        SecItemDelete(query as CFDictionary)
    }
}

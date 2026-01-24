import Foundation
import Security

enum KeychainManager {
    private static let service = "com.aptove.agentcredentials"
    
    static func save(config: ConnectionConfig, for agentId: String) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(config)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: agentId,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        SecItemDelete(query as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }
    
    static func retrieve(for agentId: String) throws -> ConnectionConfig {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: agentId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data else {
            throw KeychainError.retrieveFailed(status)
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(ConnectionConfig.self, from: data)
    }
    
    static func delete(for agentId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: agentId
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
    
    enum KeychainError: LocalizedError {
        case saveFailed(OSStatus)
        case retrieveFailed(OSStatus)
        case deleteFailed(OSStatus)
        
        var errorDescription: String? {
            switch self {
            case .saveFailed(let status):
                return "Failed to save to keychain: \(status)"
            case .retrieveFailed(let status):
                return "Failed to retrieve from keychain: \(status)"
            case .deleteFailed(let status):
                return "Failed to delete from keychain: \(status)"
            }
        }
    }
}

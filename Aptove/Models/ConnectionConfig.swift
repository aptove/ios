import Foundation

struct ConnectionConfig: Codable {
    let url: String
    let clientId: String
    let clientSecret: String
    let protocolVersion: String
    let version: String
    
    enum CodingKeys: String, CodingKey {
        case url
        case clientId
        case clientSecret
        case protocolVersion = "protocol"
        case version
    }
    
    init(url: String, clientId: String, clientSecret: String, protocolVersion: String = "acp", version: String = "1.0.0") {
        self.url = url
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.protocolVersion = protocolVersion
        self.version = version
    }
    
    func validate() throws {
        guard url.hasPrefix("https://") else {
            throw ValidationError.invalidURL("URL must use HTTPS")
        }
        
        guard protocolVersion == "acp" else {
            throw ValidationError.invalidProtocol("Protocol version must be 'acp'")
        }
        
        guard !clientId.isEmpty else {
            throw ValidationError.missingField("Client ID is required")
        }
        
        guard !clientSecret.isEmpty else {
            throw ValidationError.missingField("Client secret is required")
        }
    }
    
    var websocketURL: String {
        url.replacingOccurrences(of: "https://", with: "wss://")
    }
    
    enum ValidationError: LocalizedError {
        case invalidURL(String)
        case invalidProtocol(String)
        case missingField(String)
        
        var errorDescription: String? {
            switch self {
            case .invalidURL(let message),
                 .invalidProtocol(let message),
                 .missingField(let message):
                return message
            }
        }
    }
}

import Foundation

struct ConnectionConfig: Codable {
    let url: String
    let clientId: String?
    let clientSecret: String?
    let authToken: String?
    let certFingerprint: String?
    let protocolVersion: String
    let version: String
    /// The working directory where the bridge was started (provided during pairing).
    let cwd: String
    /// Stable bridge agent UUID used for multi-transport deduplication (present in static JSON QR codes).
    let agentId: String?

    enum CodingKeys: String, CodingKey {
        case url
        case clientId
        case clientSecret
        case authToken
        case certFingerprint
        case protocolVersion = "protocol"
        case version
        case cwd
        case agentId
    }

    init(url: String, clientId: String? = nil, clientSecret: String? = nil, authToken: String? = nil, certFingerprint: String? = nil, protocolVersion: String = "acp", version: String = "1.0.0", cwd: String, agentId: String? = nil) {
        self.url = url
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.authToken = authToken
        self.certFingerprint = certFingerprint
        self.protocolVersion = protocolVersion
        self.version = version
        self.cwd = cwd
        self.agentId = agentId
    }
    
    func validate() throws {
        // Allow both ws:// (local development) and wss:// (production)
        guard url.hasPrefix("wss://") || url.hasPrefix("ws://") || url.hasPrefix("https://") || url.hasPrefix("http://") else {
            throw ValidationError.invalidURL("URL must use WebSocket (ws:// or wss://) or HTTP (http:// or https://) protocol")
        }
        
        guard protocolVersion == "acp" else {
            throw ValidationError.invalidProtocol("Protocol version must be 'acp'")
        }
        
        // Only require client credentials for Cloudflare Zero Trust connections (https://)
        // Local TLS connections (wss://) use auth token instead
        let isCloudflare = url.hasPrefix("https://")
        if isCloudflare {
            guard let clientId = clientId, !clientId.isEmpty else {
                throw ValidationError.missingField("Client ID is required for Cloudflare connections")
            }
            
            guard let clientSecret = clientSecret, !clientSecret.isEmpty else {
                throw ValidationError.missingField("Client secret is required for Cloudflare connections")
            }
        }
    }
    
    /// Whether this is a secure TLS connection
    var isSecure: Bool {
        url.hasPrefix("wss://") || url.hasPrefix("https://")
    }
    
    /// Whether this connection uses a self-signed certificate (has fingerprint)
    var hasSelfSignedCert: Bool {
        certFingerprint != nil && !certFingerprint!.isEmpty
    }
    
    var websocketURL: String {
        url.replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
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

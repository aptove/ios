import Foundation

enum ConnectionStatus: String, Codable {
    case connected
    case disconnected
    case error
}

struct Agent: Identifiable, Codable {
    let id: String
    let name: String
    let url: String
    var capabilities: [String: String]
    var status: ConnectionStatus
    
    // Session persistence fields
    var activeSessionId: String?
    var sessionStartedAt: Date?
    var supportsLoadSession: Bool
    
    init(id: String, name: String, url: String, capabilities: [String: String] = [:], status: ConnectionStatus = .disconnected, activeSessionId: String? = nil, sessionStartedAt: Date? = nil, supportsLoadSession: Bool = false) {
        self.id = id
        self.name = name
        self.url = url
        self.capabilities = capabilities
        self.status = status
        self.activeSessionId = activeSessionId
        self.sessionStartedAt = sessionStartedAt
        self.supportsLoadSession = supportsLoadSession
    }
}

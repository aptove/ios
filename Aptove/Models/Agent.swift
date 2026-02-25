import Foundation

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

    // Multi-transport fields
    /// Stable UUID from the bridge; nil for legacy agents (no bridgeAgentId in QR).
    var bridgeAgentId: String?
    /// User-selected preferred transport (e.g. "tailscale-serve", "cloudflare", "local").
    var preferredTransport: String?

    init(
        id: String,
        name: String,
        url: String,
        capabilities: [String: String] = [:],
        status: ConnectionStatus = .disconnected,
        activeSessionId: String? = nil,
        sessionStartedAt: Date? = nil,
        supportsLoadSession: Bool = false,
        bridgeAgentId: String? = nil,
        preferredTransport: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.capabilities = capabilities
        self.status = status
        self.activeSessionId = activeSessionId
        self.sessionStartedAt = sessionStartedAt
        self.supportsLoadSession = supportsLoadSession
        self.bridgeAgentId = bridgeAgentId
        self.preferredTransport = preferredTransport
    }
}

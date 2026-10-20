import Foundation

/// The ACP protocol version the mobile client should use when connecting to an agent.
enum ACPVersionMode: String, Codable, CaseIterable {
    /// Probe for v2; fall back to v1 if the agent doesn't support it (default).
    case auto
    /// Always use v1; skip the v2 negotiation entirely.
    case v1
    /// Require v2; fail with an error if the agent doesn't support it.
    case v2

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .v1:   return "V1"
        case .v2:   return "V2"
        }
    }

    var description: String {
        switch self {
        case .auto: return "Use V2 if supported, otherwise fall back to V1"
        case .v1:   return "Always use V1"
        case .v2:   return "Require V2 (error if agent doesn't support it)"
        }
    }
}

struct Agent: Identifiable, Codable {
    let id: String
    var name: String
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

    /// User-selected ACP protocol version mode for this agent.
    var acpVersionMode: ACPVersionMode

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
        preferredTransport: String? = nil,
        acpVersionMode: ACPVersionMode = .auto
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
        self.acpVersionMode = acpVersionMode
    }
}

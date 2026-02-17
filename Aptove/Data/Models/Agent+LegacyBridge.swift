import Foundation
import CoreData

extension AgentEntity {
    /// Convert this CoreData AgentEntity to an Agent struct for use in ViewModels
    func toModel() -> Agent {
        return Agent(
            id: agentId ?? UUID().uuidString,
            name: name ?? "Unknown Agent",
            url: url ?? "",
            capabilities: parseCapabilities(),
            status: toModelStatus(),
            activeSessionId: activeSessionId,
            sessionStartedAt: sessionStartedAt,
            supportsLoadSession: supportsLoadSession
        )
    }

    /// Parse JSON capabilities string to dictionary
    private func parseCapabilities() -> [String: String] {
        guard let capabilitiesString = capabilities,
              let data = capabilitiesString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return json
    }

    /// Convert CoreData ConnectionStatus to Agent struct's ConnectionStatus enum
    private func toModelStatus() -> Agent.ConnectionStatus {
        switch status {
        case .connected:
            return .connected
        case .disconnected, .reconnecting:
            return .disconnected
        }
    }
}

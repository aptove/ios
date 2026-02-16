import Foundation
import CoreData

/// Agent struct for use in ViewModels (defined in Models/Agent.swift)
/// Imported here to reference in the extension below
/// This is the "old" struct-based model, kept for backward compatibility
typealias AgentModel = Agent

/// Extension to convert CoreData Agent entity to the AgentModel struct
/// The CoreData entity "Agent" (NSManagedObject) and the struct "Agent" can coexist
/// because they are different types. This extension is on the NSManagedObject.
extension Agent {
    /// Convert this CoreData Agent entity to an AgentModel struct
    /// for use in ViewModels
    func toModel() -> AgentModel {
        return AgentModel(
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

    /// Convert CoreData ConnectionStatus enum to AgentModel ConnectionStatus enum
    private func toModelStatus() -> ConnectionStatus {
        switch status {
        case .connected:
            return .connected
        case .disconnected:
            return .disconnected
        case .reconnecting:
            return .disconnected  // Map reconnecting to disconnected for model
        }
    }
}

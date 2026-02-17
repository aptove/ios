import Foundation
import CoreData

@objc(AgentEntity)
public class AgentEntity: NSManagedObject {
    /// Computed property for connection status with type safety
    var status: ConnectionStatus {
        get {
            switch connectionStatus {
            case "CONNECTED": return .connected
            case "RECONNECTING": return .reconnecting
            case "DISCONNECTED", nil: return .disconnected
            default: return .disconnected
            }
        }
        set {
            switch newValue {
            case .connected: connectionStatus = "CONNECTED"
            case .disconnected: connectionStatus = "DISCONNECTED"
            case .reconnecting: connectionStatus = "RECONNECTING"
            }
        }
    }

    /// Computed color hue based on agentId hash
    func updateColorHue() {
        guard let id = agentId else { return }
        let hash = abs(id.hashValue)
        colorHue = Float(hash % 360)
    }

    /// Convenience initializer
    convenience init(context: NSManagedObjectContext,
                    agentId: String,
                    name: String,
                    url: String,
                    protocolVersion: String = "1") {
        self.init(context: context)
        self.agentId = agentId
        self.name = name
        self.url = url
        self.protocolVersion = protocolVersion
        self.capabilities = "[]"
        self.connectionStatus = "DISCONNECTED"
        self.createdAt = Date()
        self.supportsLoadSession = false
        updateColorHue()
    }
}

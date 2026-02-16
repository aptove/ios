import Foundation
import CoreData

@objc(Agent)
public class Agent: NSManagedObject {
    /// Computed property for connection status with type safety
    /// Matches old Agent struct's status property
    var status: ConnectionStatus {
        get {
            // Map database values to enum
            switch connectionStatus {
            case "CONNECTED": return .connected
            case "RECONNECTING": return .reconnecting
            case "DISCONNECTED", nil: return .disconnected
            default: return .disconnected
            }
        }
        set {
            // Map enum to database values (match Android)
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

        // Set color hue based on agentId
        updateColorHue()
    }
}

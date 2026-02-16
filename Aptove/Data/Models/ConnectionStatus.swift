import Foundation

/// Connection status enum matching Android's ConnectionStatus
/// Also compatible with legacy iOS values for migration
enum ConnectionStatus: String, Codable {
    case connected
    case disconnected
    case reconnecting

    /// Default status for new agents
    static var `default`: ConnectionStatus {
        return .disconnected
    }

    /// Android database value (uppercase)
    var androidValue: String {
        switch self {
        case .connected: return "CONNECTED"
        case .disconnected: return "DISCONNECTED"
        case .reconnecting: return "RECONNECTING"
        }
    }

    /// Initialize from Android database value
    init(androidValue: String) {
        switch androidValue {
        case "CONNECTED": self = .connected
        case "RECONNECTING": self = .reconnecting
        default: self = .disconnected
        }
    }
}

import Foundation
import SwiftUI

@MainActor
class QRScannerViewModel: ObservableObject {
    @Published var showingError = false
    @Published var showingSuccess = false
    @Published var errorMessage: String?
    
    private var agentManager: AgentManager?
    
    func setAgentManager(_ manager: AgentManager) {
        self.agentManager = manager
    }
    
    func handleQRCode(_ qrString: String) async {
        do {
            guard let data = qrString.data(using: .utf8) else {
                throw ScanError.invalidData
            }
            
            let decoder = JSONDecoder()
            let config = try decoder.decode(ConnectionConfig.self, from: data)
            
            try config.validate()
            
            guard config.protocolVersion == "acp" else {
                throw ScanError.unsupportedProtocol(config.protocolVersion)
            }
            
            let success = await testConnection(config: config)
            
            if success {
                let agentId = UUID().uuidString
                let agentName = extractAgentName(from: config.url)
                
                guard let manager = agentManager else {
                    throw ScanError.noAgentManager
                }
                
                try manager.addAgent(
                    config: config,
                    agentId: agentId,
                    name: agentName
                )
                
                showingSuccess = true
            } else {
                throw ScanError.connectionFailed
            }
            
        } catch let error as ConnectionConfig.ValidationError {
            errorMessage = error.localizedDescription
            showingError = true
        } catch let error as ScanError {
            errorMessage = error.localizedDescription
            showingError = true
        } catch {
            errorMessage = "Failed to parse QR code: \(error.localizedDescription)"
            showingError = true
        }
    }
    
    func handleManualConnection(_ config: ConnectionConfig) async {
        do {
            try config.validate()
            
            let success = await testConnection(config: config)
            
            if success {
                let agentId = UUID().uuidString
                let agentName = extractAgentName(from: config.url)
                
                guard let manager = agentManager else {
                    throw ScanError.noAgentManager
                }
                
                try manager.addAgent(
                    config: config,
                    agentId: agentId,
                    name: agentName
                )
                
                showingSuccess = true
            } else {
                throw ScanError.connectionFailed
            }
            
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
    
    private func testConnection(config: ConnectionConfig) async -> Bool {
        // Use extended timeout (5 minutes) and 2 retries for QR code connections
        let wrapper = ACPClientWrapper(config: config, agentId: "test", connectionTimeout: 300, maxRetries: 2)
        
        await wrapper.connect()
        
        let isConnected: Bool
        switch wrapper.connectionState {
        case .connected:
            isConnected = true
        case .error(let message):
            // Store detailed error message
            self.errorMessage = message
            isConnected = false
        default:
            isConnected = false
        }
        
        await wrapper.disconnect()
        
        return isConnected
    }
    
    private func extractAgentName(from url: String) -> String {
        guard let components = URLComponents(string: url),
              let host = components.host else {
            return "Unknown Agent"
        }
        
        let parts = host.split(separator: ".")
        if let firstPart = parts.first {
            return String(firstPart).capitalized + " Agent"
        }
        
        return "Unknown Agent"
    }
    
    enum ScanError: LocalizedError {
        case invalidData
        case unsupportedProtocol(String)
        case connectionFailed
        case noAgentManager
        
        var errorDescription: String? {
            switch self {
            case .invalidData:
                return "Invalid QR code data"
            case .unsupportedProtocol(let version):
                return "Unsupported protocol version: \(version)"
            case .connectionFailed:
                return "Failed to connect to agent"
            case .noAgentManager:
                return "Agent manager not initialized"
            }
        }
    }
}

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
        print("📷 QRScannerViewModel.handleQRCode(): Starting QR processing...")
        print("📷 QRScannerViewModel.handleQRCode(): QR string length: \(qrString.count)")
        do {
            print("📷 QRScannerViewModel.handleQRCode(): Converting to UTF8 data...")
            guard let data = qrString.data(using: .utf8) else {
                print("❌ QRScannerViewModel.handleQRCode(): Failed to convert to UTF8")
                throw ScanError.invalidData
            }
            
            print("📷 QRScannerViewModel.handleQRCode(): Decoding JSON...")
            let decoder = JSONDecoder()
            let config = try decoder.decode(ConnectionConfig.self, from: data)
            print("✅ QRScannerViewModel.handleQRCode(): Config decoded successfully")
            print("📷 QRScannerViewModel.handleQRCode(): URL: \(config.url)")
            print("📷 QRScannerViewModel.handleQRCode(): Protocol: \(config.protocolVersion)")
            
            print("📷 QRScannerViewModel.handleQRCode(): Validating config...")
            try config.validate()
            print("✅ QRScannerViewModel.handleQRCode(): Config validated")
            
            guard config.protocolVersion == "acp" else {
                print("❌ QRScannerViewModel.handleQRCode(): Unsupported protocol: \(config.protocolVersion)")
                throw ScanError.unsupportedProtocol(config.protocolVersion)
            }
            
            print("📷 QRScannerViewModel.handleQRCode(): Testing connection...")
            let success = await testConnection(config: config)
            print("📷 QRScannerViewModel.handleQRCode(): Connection test result: \(success)")
            
            if success {
                print("✅ QRScannerViewModel.handleQRCode(): Connection successful, adding agent...")
                let agentId = UUID().uuidString
                let agentName = extractAgentName(from: config.url)
                print("📷 QRScannerViewModel.handleQRCode(): Agent ID: \(agentId), Name: \(agentName)")
                
                guard let manager = agentManager else {
                    print("❌ QRScannerViewModel.handleQRCode(): No agent manager!")
                    throw ScanError.noAgentManager
                }
                
                print("📷 QRScannerViewModel.handleQRCode(): Calling manager.addAgent()...")
                try manager.addAgent(
                    config: config,
                    agentId: agentId,
                    name: agentName
                )
                print("✅ QRScannerViewModel.handleQRCode(): Agent added successfully")
                
                showingSuccess = true
            } else {
                print("❌ QRScannerViewModel.handleQRCode(): Connection test failed")
                throw ScanError.connectionFailed
            }
            
        } catch let error as ConnectionConfig.ValidationError {
            print("❌ QRScannerViewModel.handleQRCode(): Validation error: \(error)")
            errorMessage = error.localizedDescription
            showingError = true
        } catch let error as ScanError {
            print("❌ QRScannerViewModel.handleQRCode(): Scan error: \(error)")
            errorMessage = error.localizedDescription
            showingError = true
        } catch {
            print("❌ QRScannerViewModel.handleQRCode(): Unexpected error: \(error)")
            errorMessage = "Failed to parse QR code: \(error.localizedDescription)"
            showingError = true
        }
        print("📷 QRScannerViewModel.handleQRCode(): Method complete")
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
        print("🧪 QRScannerViewModel.testConnection(): Creating test wrapper...")
        // Use extended timeout (5 minutes) and 2 retries for QR code connections
        let wrapper = ACPClientWrapper(config: config, agentId: "test", connectionTimeout: 300, maxRetries: 2)
        print("🧪 QRScannerViewModel.testConnection(): Test wrapper created, calling connect()...")
        
        await wrapper.connect()
        print("🧪 QRScannerViewModel.testConnection(): Connect() returned, checking state...")
        
        let isConnected: Bool
        switch wrapper.connectionState {
        case .connected:
            print("✅ QRScannerViewModel.testConnection(): Connection successful")
            isConnected = true
        case .error(let message):
            print("❌ QRScannerViewModel.testConnection(): Connection error: \(message)")
            // Store detailed error message
            self.errorMessage = message
            isConnected = false
        default:
            print("❌ QRScannerViewModel.testConnection(): Unexpected state: \(wrapper.connectionState)")
            isConnected = false
        }
        
        print("🧪 QRScannerViewModel.testConnection(): Disconnecting test wrapper...")
        await wrapper.disconnect()
        print("🧪 QRScannerViewModel.testConnection(): Test complete, result: \(isConnected)")
        
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

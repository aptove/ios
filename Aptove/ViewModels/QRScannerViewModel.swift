import Foundation
import SwiftUI

@MainActor
class QRScannerViewModel: ObservableObject {
    @Published var showingError = false
    @Published var showingSuccess = false
    @Published var errorMessage: String?
    @Published var pairingStatus: String = ""
    
    private var agentManager: AgentManager?
    private let pairingService = PairingService()
    
    func setAgentManager(_ manager: AgentManager) {
        self.agentManager = manager
    }
    
    func handleQRCode(_ qrString: String) async {
        print("📷 QRScannerViewModel.handleQRCode(): Starting QR processing...")
        print("📷 QRScannerViewModel.handleQRCode(): QR string length: \(qrString.count)")
        print("📷 QRScannerViewModel.handleQRCode(): Content preview: \(String(qrString.prefix(100)))")
        
        do {
            let config: ConnectionConfig
            
            // Determine if this is a pairing URL or legacy JSON format
            if qrString.hasPrefix("https://") || qrString.hasPrefix("http://") {
                // New pairing URL format
                print("📷 QRScannerViewModel.handleQRCode(): Detected pairing URL format")
                config = try await handlePairingURL(qrString)
            } else {
                // Legacy JSON format (for backwards compatibility)
                print("📷 QRScannerViewModel.handleQRCode(): Detected legacy JSON format")
                config = try handleLegacyJSON(qrString)
            }
            
            // Continue with common flow
            try await connectWithConfig(config)
            
        } catch let error as PairingError {
            print("❌ QRScannerViewModel.handleQRCode(): Pairing error: \(error)")
            errorMessage = error.localizedDescription
            showingError = true
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
            errorMessage = "Failed to process QR code: \(error.localizedDescription)"
            showingError = true
        }
        
        pairingStatus = ""
        print("📷 QRScannerViewModel.handleQRCode(): Method complete")
    }
    
    /// Handle new pairing URL format (https://IP:PORT/pair/local?code=XXXX&fp=SHA256:...)
    private func handlePairingURL(_ urlString: String) async throws -> ConnectionConfig {
        // Parse the pairing URL
        pairingStatus = "Parsing pairing URL..."
        let pairingURL = try PairingURL.parse(urlString)
        
        print("📷 QRScannerViewModel: Pairing type: \(pairingURL.pairingType.description)")
        print("📷 QRScannerViewModel: Code: \(pairingURL.code)")
        print("📷 QRScannerViewModel: Fingerprint: \(pairingURL.fingerprint ?? "none")")
        
        // Update status based on pairing type
        switch pairingURL.pairingType {
        case .local:
            pairingStatus = "Connecting to local bridge...\nValidating certificate..."
        case .cloudflare:
            pairingStatus = "Connecting to Cloudflare tunnel..."
        case .unknown(let path):
            throw PairingError.unsupportedPairingType(path)
        }
        
        // Complete the pairing flow
        let config = try await pairingService.pair(with: pairingURL)
        
        print("✅ QRScannerViewModel: Pairing successful!")
        print("📷 QRScannerViewModel: WebSocket URL: \(config.url)")
        
        return config
    }
    
    /// Handle legacy JSON format for backwards compatibility
    private func handleLegacyJSON(_ jsonString: String) throws -> ConnectionConfig {
        print("📷 QRScannerViewModel: Parsing legacy JSON...")
        
        guard let data = jsonString.data(using: .utf8) else {
            print("❌ QRScannerViewModel: Failed to convert to UTF8")
            throw ScanError.invalidData
        }
        
        let decoder = JSONDecoder()
        let config = try decoder.decode(ConnectionConfig.self, from: data)
        
        print("✅ QRScannerViewModel: Legacy config decoded")
        print("📷 QRScannerViewModel: URL: \(config.url)")
        
        return config
    }
    
    /// Common flow after obtaining ConnectionConfig
    private func connectWithConfig(_ config: ConnectionConfig) async throws {
        pairingStatus = "Validating configuration..."
        
        print("📷 QRScannerViewModel.connectWithConfig(): Validating config...")
        try config.validate()
        print("✅ QRScannerViewModel.connectWithConfig(): Config validated")
        
        guard config.protocolVersion == "acp" else {
            print("❌ QRScannerViewModel.connectWithConfig(): Unsupported protocol: \(config.protocolVersion)")
            throw ScanError.unsupportedProtocol(config.protocolVersion)
        }
        
        guard let manager = agentManager else {
            print("❌ QRScannerViewModel.connectWithConfig(): No agent manager!")
            throw ScanError.noAgentManager
        }
        
        // Check if agent already exists - if so, update credentials instead of rejecting
        if let existingAgent = manager.findAgent(withURL: config.url, clientId: config.clientId) {
            print("📷 QRScannerViewModel.connectWithConfig(): Agent exists, updating credentials for \(existingAgent.id)")
            pairingStatus = "Updating existing agent credentials..."
            
            try await manager.updateAgentCredentials(agentId: existingAgent.id, config: config)
            
            pairingStatus = "Testing connection..."
            let (success, _) = await testConnectionWithName(config: config)
            
            if success {
                print("✅ QRScannerViewModel.connectWithConfig(): Credentials updated and connection verified")
                showingSuccess = true
            } else {
                print("❌ QRScannerViewModel.connectWithConfig(): Connection test failed after update")
                throw ScanError.connectionFailed
            }
            return
        }
        
        pairingStatus = "Testing connection to agent..."
        print("📷 QRScannerViewModel.connectWithConfig(): Testing connection...")
        let (success, agentName) = await testConnectionWithName(config: config)
        print("📷 QRScannerViewModel.connectWithConfig(): Connection test result: \(success), name: \(agentName ?? "nil")")
        
        if success {
            pairingStatus = "Adding agent..."
            print("✅ QRScannerViewModel.connectWithConfig(): Connection successful, adding agent...")
            let agentId = UUID().uuidString
            let finalName = agentName ?? extractAgentName(from: config.url)
            print("📷 QRScannerViewModel.connectWithConfig(): Agent ID: \(agentId), Name: \(finalName)")
            
            print("📷 QRScannerViewModel.connectWithConfig(): Calling manager.addAgent()...")
            try manager.addAgent(
                config: config,
                agentId: agentId,
                name: finalName
            )
            print("✅ QRScannerViewModel.connectWithConfig(): Agent added successfully")
            
            showingSuccess = true
        } else {
            print("❌ QRScannerViewModel.connectWithConfig(): Connection test failed")
            throw ScanError.connectionFailed
        }
    }
    
    /// Test connection and return both success status and agent's self-reported name
    private func testConnectionWithName(config: ConnectionConfig) async -> (success: Bool, agentName: String?) {
        print("🧪 QRScannerViewModel.testConnectionWithName(): Creating test wrapper...")
        let wrapper = ACPClientWrapper(config: config, agentId: "test", connectionTimeout: 300, maxRetries: 2)
        print("🧪 QRScannerViewModel.testConnectionWithName(): Test wrapper created, calling connect()...")
        
        await wrapper.connect()
        print("🧪 QRScannerViewModel.testConnectionWithName(): Connect() returned, checking state...")
        
        let isConnected: Bool
        let agentName: String?
        
        switch wrapper.connectionState {
        case .connected:
            print("✅ QRScannerViewModel.testConnectionWithName(): Connection successful")
            isConnected = true
            agentName = wrapper.connectedAgentName
            print("🤖 QRScannerViewModel.testConnectionWithName(): Agent name: \(agentName ?? "nil")")
        case .error(let message):
            print("❌ QRScannerViewModel.testConnectionWithName(): Connection error: \(message)")
            self.errorMessage = message
            isConnected = false
            agentName = nil
        default:
            print("❌ QRScannerViewModel.testConnectionWithName(): Unexpected state: \(wrapper.connectionState)")
            isConnected = false
            agentName = nil
        }
        
        print("🧪 QRScannerViewModel.testConnectionWithName(): Disconnecting test wrapper...")
        await wrapper.disconnect()
        print("🧪 QRScannerViewModel.testConnectionWithName(): Test complete")
        
        return (isConnected, agentName)
    }
    
    @available(*, deprecated, message: "Use testConnectionWithName instead")
    private func testConnection(config: ConnectionConfig) async -> Bool {
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
        case duplicateAgent
        
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
            case .duplicateAgent:
                return "This agent is already connected"
            }
        }
    }
}

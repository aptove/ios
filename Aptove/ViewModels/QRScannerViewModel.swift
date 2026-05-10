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
            // Determine if this is a pairing URL or legacy JSON format
            if qrString.hasPrefix("https://") || qrString.hasPrefix("http://") {
                // New pairing URL format — multi-transport aware
                print("📷 QRScannerViewModel.handleQRCode(): Detected pairing URL format")
                try await handlePairingURLFull(qrString)
            } else {
                // Legacy JSON format (for backwards compatibility)
                print("📷 QRScannerViewModel.handleQRCode(): Detected legacy JSON format")
                let config = try handleLegacyJSON(qrString)
                // Infer transport from config fields (clientId present → Cloudflare)
                let transport: String? = config.clientId != nil ? "cloudflare" : nil
                try await connectWithConfig(config, bridgeAgentId: config.agentId, transport: transport)
            }
            
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
    private func handlePairingURLFull(_ urlString: String) async throws {
        pairingStatus = "Parsing pairing URL..."
        let pairingURL = try PairingURL.parse(urlString)

        print("📷 QRScannerViewModel: Pairing type: \(pairingURL.pairingType.description)")
        switch pairingURL.pairingType {
        case .local:      pairingStatus = "Connecting to local bridge...\nValidating certificate..."
        case .cloudflare: pairingStatus = "Connecting to Cloudflare tunnel..."
        case .tailscale:  pairingStatus = "Connecting via Tailscale..."
        case .unknown(let path): throw PairingError.unsupportedPairingType(path)
        }

        let result = try await pairingService.pair(with: pairingURL)
        print("✅ QRScannerViewModel: Pairing successful!")
        print("📷 QRScannerViewModel: Bridge agent ID: \(result.bridgeAgentId ?? "none")")

        // Multi-transport dedup: if bridgeAgentId matches an existing agent, add transport
        if let bridgeAgentId = result.bridgeAgentId, let manager = agentManager,
           let existingAgent = manager.findAgent(byBridgeAgentId: bridgeAgentId) {
            pairingStatus = "Adding transport to existing agent..."
            let message = try manager.addOrUpdateTransportEndpoint(
                agentId: existingAgent.id,
                transport: result.transport,
                config: result.config
            )
            // Set the newly scanned transport as preferred, then force a fresh reconnect
            // so the app switches to it immediately rather than keeping a stale connection.
            manager.setPreferredTransport(agentId: existingAgent.id, transport: result.transport)
            await manager.disconnectAgent(agentId: existingAgent.id)
            let connected = await manager.connectAgent(agentId: existingAgent.id)
            guard connected else {
                throw ScanError.connectionFailed
            }
            print("✅ QRScannerViewModel: \(message)")
            pairingStatus = message
            showingSuccess = true
            pairingStatus = ""
            return
        }

        // New agent flow
        try await connectWithConfig(result.config, bridgeAgentId: result.bridgeAgentId, transport: result.transport)
    }

    /// Handle new pairing URL format (https://IP:PORT/pair/local?code=XXXX&fp=SHA256:...)
    /// - Returns: ConnectionConfig (kept for legacy callers; new code uses handlePairingURLFull)
    private func handlePairingURL(_ urlString: String) async throws -> ConnectionConfig {
        pairingStatus = "Parsing pairing URL..."
        let pairingURL = try PairingURL.parse(urlString)
        switch pairingURL.pairingType {
        case .local:      pairingStatus = "Connecting to local bridge...\nValidating certificate..."
        case .cloudflare: pairingStatus = "Connecting to Cloudflare tunnel..."
        case .tailscale:  pairingStatus = "Connecting via Tailscale..."
        case .unknown(let path): throw PairingError.unsupportedPairingType(path)
        }
        let result = try await pairingService.pair(with: pairingURL)
        return result.config
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
    private func connectWithConfig(_ config: ConnectionConfig, bridgeAgentId: String?, transport: String?) async throws {
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

        // Multi-transport dedup: bridgeAgentId takes priority over URL matching.
        // This handles the case where the same bridge is scanned with a different transport
        // (e.g., first local, then Cloudflare — different URLs, same agent).
        if let bridgeAgentId = bridgeAgentId,
           let existingAgent = manager.findAgent(byBridgeAgentId: bridgeAgentId) {
            print("📷 QRScannerViewModel.connectWithConfig(): Found existing agent by bridgeAgentId \(bridgeAgentId), adding transport")
            pairingStatus = "Adding transport to existing agent..."
            let message = try manager.addOrUpdateTransportEndpoint(
                agentId: existingAgent.id,
                transport: transport ?? "cloudflare",
                config: config
            )
            if let transport = transport {
                manager.setPreferredTransport(agentId: existingAgent.id, transport: transport)
            }
            await manager.disconnectAgent(agentId: existingAgent.id)
            let connected = await manager.connectAgent(agentId: existingAgent.id)
            guard connected else {
                throw ScanError.connectionFailed
            }
            print("✅ QRScannerViewModel.connectWithConfig(): \(message)")
            showingSuccess = true
            return
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
            let folderName = URL(fileURLWithPath: config.cwd).lastPathComponent
            let finalName = (!folderName.isEmpty && folderName != "/") ? folderName : (agentName ?? extractAgentName(from: config.url))
            print("📷 QRScannerViewModel.connectWithConfig(): Agent ID: \(agentId), Name: \(finalName)")
            
            print("📷 QRScannerViewModel.connectWithConfig(): Calling manager.addAgent()...")
            try manager.addAgent(
                config: config,
                agentId: agentId,
                name: finalName,
                bridgeAgentId: bridgeAgentId
            )

            // Register the first transport endpoint and set it as preferred
            if let transport = transport {
                _ = try? manager.addOrUpdateTransportEndpoint(agentId: agentId, transport: transport, config: config)
                manager.setPreferredTransport(agentId: agentId, transport: transport)
            }
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
        // Use unique agent ID for each test to avoid reusing session IDs
        let wrapper = ACPClientWrapper(config: config, agentId: "test-\(UUID().uuidString)", connectionTimeout: 300, maxRetries: 2)
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
        // Use unique agent ID for each test to avoid reusing session IDs
        let wrapper = ACPClientWrapper(config: config, agentId: "test-\(UUID().uuidString)", connectionTimeout: 300, maxRetries: 2)
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

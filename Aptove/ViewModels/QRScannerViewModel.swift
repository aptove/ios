import Foundation
import SwiftUI
import os

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
        Logger.pairing.debug("handleQRCode: length=\(qrString.count), preview=\(qrString.prefix(100))")
        
        do {
            // Determine if this is a pairing URL or legacy JSON format
            if qrString.hasPrefix("https://") || qrString.hasPrefix("http://") {
                // New pairing URL format — multi-transport aware
                Logger.pairing.debug("Detected pairing URL format")
                try await handlePairingURLFull(qrString)
            } else {
                // Legacy JSON format (for backwards compatibility)
                Logger.pairing.debug("Detected legacy JSON format")
                let config = try handleLegacyJSON(qrString)
                try await connectWithConfig(config, bridgeAgentId: config.agentId, transport: nil)
            }
            
        } catch let error as PairingError {
            Logger.pairing.error("Pairing error: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            showingError = true
        } catch let error as ConnectionConfig.ValidationError {
            Logger.pairing.error("Validation error: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            showingError = true
        } catch let error as ScanError {
            Logger.pairing.error("Scan error: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            showingError = true
        } catch {
            Logger.pairing.error("Unexpected error: \(error.localizedDescription)")
            errorMessage = "Failed to process QR code: \(error.localizedDescription)"
            showingError = true
        }
        
        pairingStatus = ""
        Logger.pairing.debug("handleQRCode complete")
    }
    
    /// Handle new pairing URL format (https://IP:PORT/pair/local?code=XXXX&fp=SHA256:...)
    private func handlePairingURLFull(_ urlString: String) async throws {
        pairingStatus = "Parsing pairing URL..."
        let pairingURL = try PairingURL.parse(urlString)

        Logger.pairing.debug("Pairing type: \(pairingURL.pairingType.description)")
        switch pairingURL.pairingType {
        case .local:      pairingStatus = "Connecting to local bridge...\nValidating certificate..."
        case .tailscale:  pairingStatus = "Connecting via Tailscale..."
        case .plugin(let name):
            let label = FeatureRegistry.shared.provider(forTransport: name)?.displayName ?? name
            pairingStatus = "Connecting via \(label)..."
        }

        let result = try await pairingService.pair(with: pairingURL)
        Logger.pairing.debug("Pairing successful! bridgeAgentId=\(result.bridgeAgentId ?? "none")")

        // Multi-transport dedup: if bridgeAgentId + cwd match an existing agent, add transport.
        // cwd is used as a secondary key so two bridges with the same agent_id but different
        // working directories are correctly treated as separate agents.
        if let bridgeAgentId = result.bridgeAgentId, let manager = agentManager,
           let existingAgent = manager.findAgent(byBridgeAgentId: bridgeAgentId, cwd: result.config.cwd) {
            pairingStatus = "Adding transport to existing agent..."
            let message = try await manager.addOrUpdateTransportEndpoint(
                agentId: existingAgent.id,
                transport: result.transport,
                config: result.config
            )
            // Propagate the new auth token to all other endpoints for this bridge.
            // auth_token is bridge-wide, so every stored transport must use the same value.
            // This also clears any invalid-credential flags set by previous 401 rejections.
            await manager.updateAuthTokenForOtherEndpoints(
                agentId: existingAgent.id,
                excludingTransport: result.transport,
                newAuthToken: result.config.authToken ?? "",
                pushRelayUrl: result.config.pushRelayUrl
            )
            // Set the newly scanned transport as preferred, then force a fresh reconnect
            // so the app switches to it immediately rather than keeping a stale connection.
            manager.setPreferredTransport(agentId: existingAgent.id, transport: result.transport)
            await manager.disconnectAgent(agentId: existingAgent.id)
            // Fire reconnect in background — the QR scan's job is to register the transport,
            // not to guarantee the connection is immediately live. The agent manager's retry
            // loop handles reconnection if the first attempt fails.
            Task { await manager.connectAgent(agentId: existingAgent.id) }
            Logger.pairing.debug("Transport added: \(message)")
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
        case .tailscale:  pairingStatus = "Connecting via Tailscale..."
        case .plugin(let name):
            let label = FeatureRegistry.shared.provider(forTransport: name)?.displayName ?? name
            pairingStatus = "Connecting via \(label)..."
        }
        let result = try await pairingService.pair(with: pairingURL)
        return result.config
    }
    
    /// Handle legacy JSON format for backwards compatibility
    private func handleLegacyJSON(_ jsonString: String) throws -> ConnectionConfig {
        Logger.pairing.debug("Parsing legacy JSON...")

        guard let data = jsonString.data(using: .utf8) else {
            Logger.pairing.error("Failed to convert QR string to UTF8")
            throw ScanError.invalidData
        }
        
        let decoder = JSONDecoder()
        let config = try decoder.decode(ConnectionConfig.self, from: data)
        
        Logger.pairing.debug("Legacy config decoded, URL: \(config.url)")
        
        return config
    }
    
    /// Common flow after obtaining ConnectionConfig
    private func connectWithConfig(_ config: ConnectionConfig, bridgeAgentId: String?, transport: String?) async throws {
        pairingStatus = "Validating configuration..."
        
        Logger.pairing.debug("connectWithConfig: validating...")
        try config.validate()
        Logger.pairing.debug("Config validated")
        
        guard config.protocolVersion == "acp" else {
            Logger.pairing.error("Unsupported protocol: \(config.protocolVersion)")
            throw ScanError.unsupportedProtocol(config.protocolVersion)
        }
        
        guard let manager = agentManager else {
            Logger.pairing.error("No agent manager!")
            throw ScanError.noAgentManager
        }

        // Multi-transport dedup: bridgeAgentId + cwd take priority over URL matching.
        // This handles the case where the same bridge is scanned with a different transport
        // (e.g., first local, then Cloudflare — different URLs, same agent).
        if let bridgeAgentId = bridgeAgentId,
           let existingAgent = manager.findAgent(byBridgeAgentId: bridgeAgentId, cwd: config.cwd) {
            Logger.pairing.debug("Found existing agent by bridgeAgentId \(bridgeAgentId), adding transport")
            pairingStatus = "Adding transport to existing agent..."
            let message = try await manager.addOrUpdateTransportEndpoint(
                agentId: existingAgent.id,
                transport: transport ?? "local",
                config: config
            )
            if let transport = transport {
                manager.setPreferredTransport(agentId: existingAgent.id, transport: transport)
            }
            await manager.disconnectAgent(agentId: existingAgent.id)
            // Fire reconnect in background — the QR scan's job is to register the transport,
            // not to guarantee the connection is immediately live. The agent manager's retry
            // loop handles reconnection if the first attempt fails.
            Task { await manager.connectAgent(agentId: existingAgent.id) }
            Logger.pairing.debug("connectWithConfig: \(message)")
            showingSuccess = true
            return
        }

        // Check if the same bridge is being re-scanned (e.g. to refresh credentials).
        // Only treat it as the same agent when both sides agree on bridgeAgentId.
        // A different bridge that happens to land on the same IP/port must NOT hijack the
        // existing agent — it should be registered as a new agent instead.
        if let existingAgent = await manager.findAgent(withURL: config.url, clientId: config.clientId) {
            let isSameBridge: Bool
            if let newId = bridgeAgentId, let existingId = existingAgent.bridgeAgentId,
               !newId.isEmpty, !existingId.isEmpty {
                isSameBridge = newId == existingId
            } else {
                isSameBridge = true // no bridgeAgentId on either side — assume same (legacy)
            }

            if isSameBridge {
                Logger.pairing.debug("Agent exists, updating credentials for \(existingAgent.id)")
                pairingStatus = "Updating existing agent credentials..."

                try await manager.updateAgentCredentials(agentId: existingAgent.id, config: config)

                pairingStatus = "Testing connection..."
                let (success, _) = await testConnectionWithName(config: config)

                if success {
                    Logger.pairing.debug("Credentials updated and connection verified")
                    await manager.disconnectAgent(agentId: existingAgent.id)
                    Task { await manager.connectAgent(agentId: existingAgent.id) }
                    showingSuccess = true
                } else {
                    Logger.pairing.error("Connection test failed after credential update")
                    throw ScanError.connectionFailed
                }
                return
            }
            Logger.pairing.debug("URL matches existing agent but bridgeAgentId differs — creating new agent")
        }
        
        pairingStatus = "Testing connection to agent..."
        Logger.pairing.debug("Testing connection...")
        let (success, agentName) = await testConnectionWithName(config: config)
        Logger.pairing.debug("Connection test result: \(success), name: \(agentName ?? "nil")")
        
        if success {
            pairingStatus = "Adding agent..."
            Logger.pairing.debug("Connection successful, adding agent...")
            let agentId = UUID().uuidString
            let folderName = URL(fileURLWithPath: config.cwd).lastPathComponent
            let finalName = (!folderName.isEmpty && folderName != "/") ? folderName : (agentName ?? extractAgentName(from: config.url))
            Logger.pairing.debug("Agent ID: \(agentId), Name: \(finalName)")
            
            Logger.pairing.debug("Calling manager.addAgent()...")
            try await manager.addAgent(
                config: config,
                agentId: agentId,
                name: finalName,
                bridgeAgentId: bridgeAgentId
            )

            // Register the first transport endpoint and set it as preferred
            if let transport = transport {
                _ = try? await manager.addOrUpdateTransportEndpoint(agentId: agentId, transport: transport, config: config)
                manager.setPreferredTransport(agentId: agentId, transport: transport)
            }
            Logger.pairing.debug("Agent added successfully")
            
            showingSuccess = true
        } else {
            Logger.pairing.error("Connection test failed")
            throw ScanError.connectionFailed
        }
    }
    
    /// Test connection and return both success status and agent's self-reported name
    private func testConnectionWithName(config: ConnectionConfig) async -> (success: Bool, agentName: String?) {
        Logger.pairing.debug("testConnectionWithName: creating test wrapper...")
        // Use unique agent ID for each test to avoid reusing session IDs
        let wrapper = ACPClientWrapper(config: config, agentId: "test-\(UUID().uuidString)", connectionTimeout: 300, maxRetries: 2)
        Logger.pairing.debug("Test wrapper created, calling connect()...")
        
        await wrapper.connect()
        Logger.pairing.debug("Connect returned, checking state...")
        
        let isConnected: Bool
        let agentName: String?
        
        switch wrapper.connectionState {
        case .connected:
            Logger.pairing.debug("Test connection successful")
            isConnected = true
            agentName = wrapper.connectedAgentName
            Logger.pairing.debug("Agent name: \(agentName ?? "nil")")
        case .error(let message):
            Logger.pairing.error("Test connection error: \(message)")
            self.errorMessage = message
            isConnected = false
            agentName = nil
        default:
            Logger.pairing.error("Test connection unexpected state: \(String(describing: wrapper.connectionState))")
            isConnected = false
            agentName = nil
        }
        
        Logger.pairing.debug("Disconnecting test wrapper...")
        await wrapper.disconnect()
        Logger.pairing.debug("Test complete")
        
        return (isConnected, agentName)
    }
    
    @available(*, deprecated, message: "Use testConnectionWithName instead")
    private func testConnection(config: ConnectionConfig) async -> Bool {
        // Use unique agent ID for each test to avoid reusing session IDs
        let wrapper = ACPClientWrapper(config: config, agentId: "test-\(UUID().uuidString)", connectionTimeout: 300, maxRetries: 2)
        Logger.pairing.debug("testConnection: calling connect()...")
        
        await wrapper.connect()
        Logger.pairing.debug("testConnection: checking state...")
        
        let isConnected: Bool
        switch wrapper.connectionState {
        case .connected:
            Logger.pairing.debug("testConnection: successful")
            isConnected = true
        case .error(let message):
            Logger.pairing.error("testConnection error: \(message)")
            // Store detailed error message
            self.errorMessage = message
            isConnected = false
        default:
            Logger.pairing.error("testConnection unexpected state: \(String(describing: wrapper.connectionState))")
            isConnected = false
        }
        
        Logger.pairing.debug("testConnection: disconnecting...")
        await wrapper.disconnect()
        Logger.pairing.debug("testConnection complete, result: \(isConnected)")
        
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

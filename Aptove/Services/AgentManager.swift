import Foundation
import SwiftUI
import Combine
import CoreData

/// Thread-safe client cache using actor isolation
actor ClientCache {
    private var clients: [String: ACPClientWrapper] = [:]

    func getClient(for agentId: String) -> ACPClientWrapper? {
        return clients[agentId]
    }

    func setClient(_ client: ACPClientWrapper, for agentId: String) {
        clients[agentId] = client
    }

    func removeClient(for agentId: String) -> ACPClientWrapper? {
        return clients.removeValue(forKey: agentId)
    }
}

@MainActor
class AgentManager: ObservableObject {
    @Published var agents: [Agent] = []
    @Published var conversations: [String: Conversation] = [:]

    private let clientCache = ClientCache()
    private let repository: AgentRepository
    private var cancellables = Set<AnyCancellable>()

    init(repository: AgentRepository = AgentRepository()) {
        print("📱 AgentManager: Initializing with CoreData repository...")
        self.repository = repository
        setupObservers()
        print("📱 AgentManager: Initialization complete, loaded \(agents.count) agents")
    }

    /// Set up reactive observers for repository changes
    private func setupObservers() {
        repository.observeAgents()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] coreDataAgents in
                guard let self = self else { return }
                self.agents = coreDataAgents.map { $0.toModel() }
                self.sortAgents()
            }
            .store(in: &cancellables)
    }
    
    /// Check if an agent with the same URL (and clientId for Cloudflare) already exists
    func hasAgent(withURL url: String, clientId: String?) -> Bool {
        return findAgent(withURL: url, clientId: clientId) != nil
    }

    /// Find an existing agent by URL (and clientId for Cloudflare)
    func findAgent(withURL url: String, clientId: String?) -> Agent? {
        // Normalize URL for comparison (remove trailing slash)
        let normalizedURL = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        return agents.first { agent in
            let agentURL = agent.url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            // For local connections (no clientId), just compare URLs
            if clientId == nil || clientId?.isEmpty == true {
                return agentURL == normalizedURL
            }

            // For Cloudflare connections, need to match both URL and clientId
            // But we don't store clientId in Agent, so we check via Keychain
            if agentURL == normalizedURL {
                if let storedConfig = try? KeychainManager.retrieve(for: agent.id) {
                    return storedConfig.clientId == clientId
                }
            }
            return false
        }
    }
    
    func addAgent(config: ConnectionConfig, agentId: String, name: String) throws {
        try config.validate()

        // Save credentials to Keychain
        try KeychainManager.save(config: config, for: agentId)

        // Add agent to repository
        repository.addAgent(
            agentId: agentId,
            name: name,
            url: config.url,
            protocolVersion: config.protocolVersion
        )

        // Create conversation
        conversations[agentId] = Conversation(agentId: agentId)

        print("✅ AgentManager: Added agent \(name) (\(agentId))")
    }
    
    /// Update credentials for an existing agent (when re-scanning QR after bridge restart)
    func updateAgentCredentials(agentId: String, config: ConnectionConfig) async throws {
        try config.validate()

        print("📱 AgentManager: Updating credentials for agent \(agentId)")

        // Disconnect and remove cached client
        if let client = await clientCache.removeClient(for: agentId) {
            await client.disconnect()
        }

        // Update keychain with new credentials
        try KeychainManager.save(config: config, for: agentId)

        // Clear session info since credentials changed
        repository.clearSessionInfo(agentId: agentId)
        repository.updateConnectionStatus(agentId: agentId, status: .disconnected)

        // Clear conversation for fresh start
        conversations[agentId] = Conversation(agentId: agentId)

        print("📱 AgentManager: Credentials updated successfully for \(agentId)")
    }
    
    func removeAgent(agentId: String) async {
        let client = await clientCache.removeClient(for: agentId)

        if let client = client {
            await client.disconnect()
        }

        // Remove from repository
        repository.deleteAgent(agentId: agentId)

        // Remove conversation
        conversations.removeValue(forKey: agentId)

        // Remove credentials
        try? KeychainManager.delete(for: agentId)

        print("🗑️ AgentManager: Removed agent \(agentId)")
    }
    
    func getClient(for agentId: String) async -> ACPClientWrapper? {
        let startTime = CFAbsoluteTimeGetCurrent()
        print("📱 AgentManager.getClient: START for \(agentId)")
        
        // Check cache first
        if let existingClient = await clientCache.getClient(for: agentId) {
            print("📱 AgentManager.getClient: Cache HIT (\(Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000))ms)")
            return existingClient
        }
        
        print("📱 AgentManager.getClient: Cache MISS, creating new client...")
        
        let keychainStart = CFAbsoluteTimeGetCurrent()
        guard let config = try? KeychainManager.retrieve(for: agentId) else {
            print("❌ AgentManager.getClient: Keychain FAILED (\(Int((CFAbsoluteTimeGetCurrent() - keychainStart) * 1000))ms)")
            return nil
        }
        print("📱 AgentManager.getClient: Keychain retrieved (\(Int((CFAbsoluteTimeGetCurrent() - keychainStart) * 1000))ms)")
        
        // Get existing session ID if available
        let existingSessionId = agents.first(where: { $0.id == agentId })?.activeSessionId
        if let sessionId = existingSessionId {
            print("📱 AgentManager.getClient: Found existing session ID: \(sessionId)")
        }
        
        let initStart = CFAbsoluteTimeGetCurrent()
        let client = ACPClientWrapper(config: config, agentId: agentId)
        print("📱 AgentManager.getClient: Client created (\(Int((CFAbsoluteTimeGetCurrent() - initStart) * 1000))ms)")
        
        await clientCache.setClient(client, for: agentId)
        print("📱 AgentManager.getClient: TOTAL TIME: \(Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000))ms")
        return client
    }
    
    /// Get or create a client and connect with session persistence
    func getConnectedClient(for agentId: String) async -> ACPClientWrapper? {
        guard let client = await getClient(for: agentId) else {
            return nil
        }
        
        // If already connected, mark as resumed (reusing existing session) and return
        if case .connected = client.connectionState {
            client.sessionWasResumed = true
            return client
        }
        
        // Get existing session ID for resumption
        let existingSessionId = agents.first(where: { $0.id == agentId })?.activeSessionId
        
        // Connect with session loading
        await client.connect(existingSessionId: existingSessionId)
        
        // Update agent with session info after connection
        if case .connected = client.connectionState {
            updateAgentSessionInfo(
                agentId: agentId,
                sessionId: client.sessionId,
                supportsLoadSession: client.supportsLoadSession
            )
        }
        
        return client
    }
    
    /// Update agent's session information
    func updateAgentSessionInfo(agentId: String, sessionId: String?, supportsLoadSession: Bool) {
        repository.updateSessionInfo(
            agentId: agentId,
            sessionId: sessionId,
            supportsLoad: supportsLoadSession
        )
        print("📱 AgentManager: Updated session info for \(agentId): sessionId=\(sessionId ?? "nil"), supportsLoad=\(supportsLoadSession)")
    }

    /// Clear the session for an agent (for "Clear Session" button)
    func clearSession(for agentId: String) async {
        // Clear session in repository
        repository.clearSessionInfo(agentId: agentId)

        // Also clear the conversation
        conversations[agentId] = Conversation(agentId: agentId)

        // Disconnect the client if connected
        if let client = await clientCache.removeClient(for: agentId) {
            await client.disconnect()
        }

        print("📱 AgentManager: Cleared session for \(agentId)")
    }
    
    func sortAgents() {
        agents.sort { agent1, agent2 in
            let lastActivity1 = conversations[agent1.id]?.lastActivity ?? .distantPast
            let lastActivity2 = conversations[agent2.id]?.lastActivity ?? .distantPast
            return lastActivity1 > lastActivity2
        }
    }
}

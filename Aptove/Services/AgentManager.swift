import Foundation
import SwiftUI

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
    
    init() {
        print("📱 AgentManager: Initializing...")
        loadAgents()
        print("📱 AgentManager: Initialization complete, loaded \(agents.count) agents")
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
        
        let agent = Agent(
            id: agentId,
            name: name,
            url: config.url,
            capabilities: [:],
            status: .disconnected,
            activeSessionId: nil,
            sessionStartedAt: nil,
            supportsLoadSession: false
        )
        
        try KeychainManager.save(config: config, for: agentId)
        
        agents.append(agent)
        conversations[agentId] = Conversation(agentId: agentId)
        
        saveAgents()
        sortAgents()
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
        if let index = agents.firstIndex(where: { $0.id == agentId }) {
            agents[index].activeSessionId = nil
            agents[index].sessionStartedAt = nil
            agents[index].status = .disconnected
        }
        
        // Clear conversation for fresh start
        conversations[agentId] = Conversation(agentId: agentId)
        
        saveAgents()
        print("📱 AgentManager: Credentials updated successfully for \(agentId)")
    }
    
    func removeAgent(agentId: String) async {
        let client = await clientCache.removeClient(for: agentId)
        
        if let client = client {
            await client.disconnect()
        }
        
        agents.removeAll { $0.id == agentId }
        conversations.removeValue(forKey: agentId)
        
        try? KeychainManager.delete(for: agentId)
        
        saveAgents()
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
        
        // If already connected, return
        if case .connected = client.connectionState {
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
        guard let index = agents.firstIndex(where: { $0.id == agentId }) else { return }
        
        agents[index].activeSessionId = sessionId
        agents[index].sessionStartedAt = sessionId != nil ? Date() : nil
        agents[index].supportsLoadSession = supportsLoadSession
        
        saveAgents()
        print("📱 AgentManager: Updated session info for \(agentId): sessionId=\(sessionId ?? "nil"), supportsLoad=\(supportsLoadSession)")
    }
    
    /// Clear the session for an agent (for "Clear Session" button)
    func clearSession(for agentId: String) async {
        guard let index = agents.firstIndex(where: { $0.id == agentId }) else { return }
        
        agents[index].activeSessionId = nil
        agents[index].sessionStartedAt = nil
        
        // Also clear the conversation
        conversations[agentId] = Conversation(agentId: agentId)
        
        // Disconnect the client if connected
        if let client = await clientCache.removeClient(for: agentId) {
            await client.disconnect()
        }
        
        saveAgents()
        print("📱 AgentManager: Cleared session for \(agentId)")
    }
    
    func sortAgents() {
        agents.sort { agent1, agent2 in
            let lastActivity1 = conversations[agent1.id]?.lastActivity ?? .distantPast
            let lastActivity2 = conversations[agent2.id]?.lastActivity ?? .distantPast
            return lastActivity1 > lastActivity2
        }
    }
    
    private func loadAgents() {
        print("📱 AgentManager: Loading saved agents from UserDefaults...")
        guard let data = UserDefaults.standard.data(forKey: "agents"),
              let loadedAgents = try? JSONDecoder().decode([Agent].self, from: data) else {
            print("📱 AgentManager: No saved agents found or decode failed")
            return
        }
        
        print("📱 AgentManager: Successfully decoded \(loadedAgents.count) agents")
        agents = loadedAgents
        
        for agent in agents {
            print("📱 AgentManager: Setting up conversation for agent: \(agent.name) (\(agent.id))")
            if conversations[agent.id] == nil {
                conversations[agent.id] = Conversation(agentId: agent.id)
            }
        }
        
        sortAgents()
    }
    
    private func saveAgents() {
        guard let data = try? JSONEncoder().encode(agents) else {
            return
        }
        UserDefaults.standard.set(data, forKey: "agents")
    }
}

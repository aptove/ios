import Foundation
import SwiftUI

@MainActor
class AgentManager: ObservableObject {
    @Published var agents: [Agent] = []
    @Published var conversations: [String: Conversation] = [:]
    
    nonisolated(unsafe) private var clients: [String: ACPClientWrapper] = [:]
    private let clientsLock = NSLock()
    
    init() {
        print("📱 AgentManager: Initializing...")
        loadAgents()
        print("📱 AgentManager: Initialization complete, loaded \(agents.count) agents")
    }
    
    func addAgent(config: ConnectionConfig, agentId: String, name: String) throws {
        try config.validate()
        
        let agent = Agent(
            id: agentId,
            name: name,
            url: config.url,
            capabilities: [:],
            status: .disconnected
        )
        
        try KeychainManager.save(config: config, for: agentId)
        
        agents.append(agent)
        conversations[agentId] = Conversation(agentId: agentId)
        
        saveAgents()
        sortAgents()
    }
    
    func removeAgent(agentId: String) async {
        clientsLock.lock()
        let client = clients[agentId]
        clients.removeValue(forKey: agentId)
        clientsLock.unlock()
        
        if let client = client {
            await client.disconnect()
        }
        
        agents.removeAll { $0.id == agentId }
        conversations.removeValue(forKey: agentId)
        
        try? KeychainManager.delete(for: agentId)
        
        saveAgents()
    }
    
    nonisolated func getClient(for agentId: String) -> ACPClientWrapper? {
        let startTime = CFAbsoluteTimeGetCurrent()
        print("📱 AgentManager.getClient: START for \(agentId)")
        
        clientsLock.lock()
        print("📱 AgentManager.getClient: Lock acquired (\(Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000))ms)")
        defer { 
            clientsLock.unlock()
            print("📱 AgentManager.getClient: Lock released, TOTAL TIME: \(Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000))ms")
        }
        
        if let existingClient = clients[agentId] {
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
        
        let initStart = CFAbsoluteTimeGetCurrent()
        let client = ACPClientWrapper(config: config, agentId: agentId)
        print("📱 AgentManager.getClient: Client created (\(Int((CFAbsoluteTimeGetCurrent() - initStart) * 1000))ms)")
        
        clients[agentId] = client
        return client
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

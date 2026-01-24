import Foundation
import SwiftUI

@MainActor
class AgentManager: ObservableObject {
    @Published var agents: [Agent] = []
    @Published var conversations: [String: Conversation] = [:]
    
    private var clients: [String: ACPClientWrapper] = [:]
    
    init() {
        loadAgents()
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
        if let client = clients[agentId] {
            await client.disconnect()
            clients.removeValue(forKey: agentId)
        }
        
        agents.removeAll { $0.id == agentId }
        conversations.removeValue(forKey: agentId)
        
        try? KeychainManager.delete(for: agentId)
        
        saveAgents()
    }
    
    func getClient(for agentId: String) -> ACPClientWrapper? {
        if let existingClient = clients[agentId] {
            return existingClient
        }
        
        guard let config = try? KeychainManager.retrieve(for: agentId) else {
            return nil
        }
        
        let client = ACPClientWrapper(config: config, agentId: agentId)
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
        guard let data = UserDefaults.standard.data(forKey: "agents"),
              let loadedAgents = try? JSONDecoder().decode([Agent].self, from: data) else {
            return
        }
        
        agents = loadedAgents
        
        for agent in agents {
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

import Foundation

@MainActor
class AgentConfigurationViewModel: ObservableObject {
    @Published var agent: Agent?
    @Published var messageCount: Int = 0
    @Published var isClearingSession: Bool = false
    @Published var isDeletingAgent: Bool = false
    @Published var error: String?
    @Published var shouldDismiss: Bool = false
    
    let agentId: String
    private var agentManager: AgentManager?
    
    init(agentId: String) {
        self.agentId = agentId
    }
    
    func setAgentManager(_ manager: AgentManager) {
        self.agentManager = manager
        loadAgentDetails()
    }
    
    private func loadAgentDetails() {
        guard let manager = agentManager else { return }
        
        agent = manager.agents.first { $0.id == agentId }
        messageCount = manager.conversations[agentId]?.messages.count ?? 0
    }
    
    func clearSession() {
        guard let manager = agentManager else { return }
        
        isClearingSession = true
        
        Task {
            await manager.clearSession(for: agentId)
            
            isClearingSession = false
            loadAgentDetails()
        }
    }
    
    func deleteAgent() {
        guard let manager = agentManager else { return }
        
        isDeletingAgent = true
        
        Task {
            await manager.removeAgent(agentId: agentId)
            
            isDeletingAgent = false
            shouldDismiss = true
        }
    }
    
    func clearError() {
        error = nil
    }
}

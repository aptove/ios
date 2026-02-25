import Foundation

/// A plain value type representing a transport endpoint for display in the UI.
struct TransportEndpointInfo: Identifiable {
    let id: String          // endpointId
    let transport: String
    let url: String
    let isActive: Bool
    let lastConnectedAt: Date?
    let priority: Int16
}

@MainActor
class AgentConfigurationViewModel: ObservableObject {
    @Published var agent: Agent?
    @Published var messageCount: Int = 0
    @Published var endpoints: [TransportEndpointInfo] = []
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
        endpoints = manager.transportEndpoints(for: agentId).compactMap { entity in
            guard let id = entity.endpointId,
                  let transport = entity.transport,
                  let url = entity.url else { return nil }
            return TransportEndpointInfo(
                id: id,
                transport: transport,
                url: url,
                isActive: entity.isActive,
                lastConnectedAt: entity.lastConnectedAt,
                priority: entity.priority
            )
        }
    }

    func setPreferredTransport(_ transport: String?) {
        agentManager?.setPreferredTransport(agentId: agentId, transport: transport)
        loadAgentDetails()
    }

    func deleteEndpoint(id: String) {
        agentManager?.deleteTransportEndpoint(agentId: agentId, endpointId: id)
        loadAgentDetails()
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

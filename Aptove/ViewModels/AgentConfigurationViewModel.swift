import Foundation
import Combine

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
    @Published var editableName: String = ""

    let agentId: String
    private var agentManager: AgentManager?
    private var cancellables = Set<AnyCancellable>()
    private var hasLoadedName = false

    init(agentId: String) {
        self.agentId = agentId
    }

    func setAgentManager(_ manager: AgentManager) {
        self.agentManager = manager
        loadAgentDetails()

        // Subscribe to agent updates for reactive transport status
        manager.$agents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadAgentDetails()
            }
            .store(in: &cancellables)
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

        // Only set editableName on first load to avoid overwriting mid-edit
        if !hasLoadedName, let name = agent?.name {
            editableName = name
            hasLoadedName = true
        }
    }

    func saveNameIfChanged() {
        let trimmed = editableName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != agent?.name else { return }
        agentManager?.renameAgent(agentId: agentId, newName: trimmed)
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

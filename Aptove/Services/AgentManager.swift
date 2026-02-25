import Foundation
import SwiftUI
import Combine

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
    private var retryTask: Task<Void, Never>?

    init(repository: AgentRepository = AgentRepository()) {
        self.repository = repository
        print("📱 AgentManager: Initializing...")
        setupAgentObserver()
        print("📱 AgentManager: Initialization complete, \(agents.count) agents loaded")
    }

    private func setupAgentObserver() {
        repository.observeAgents()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] updatedAgents in
                guard let self else { return }
                let wasEmpty = self.agents.isEmpty
                self.agents = updatedAgents
                // Create conversations for any new agents
                for agent in updatedAgents where self.conversations[agent.id] == nil {
                    self.conversations[agent.id] = Conversation(agentId: agent.id)
                }
                if wasEmpty && !updatedAgents.isEmpty {
                    print("📱 AgentManager: Loaded \(updatedAgents.count) agents from CoreData")
                    autoConnectAllAgents()
                    startBackgroundRetry()
                }
            }
            .store(in: &cancellables)
    }

    /// Auto-connect to all saved agents on first load.
    func autoConnectAllAgents() {
        print("📱 AgentManager: Auto-connecting \(agents.count) agents...")
        for agent in agents {
            let agentId = agent.id
            Task {
                _ = await self.connectAgent(agentId: agentId)
            }
        }
    }

    /// Start a background timer that retries disconnected agents every 30 seconds.
    private func startBackgroundRetry() {
        retryTask?.cancel()
        retryTask = Task {
            repeat {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
                guard !Task.isCancelled else { return }
                let disconnected = self.agents.filter { $0.status == .disconnected }
                for agent in disconnected {
                    let agentId = agent.id
                    Task {
                        _ = await self.connectAgent(agentId: agentId)
                    }
                }
            } while !Task.isCancelled
        }
    }

    /// Check if an agent with the same URL (and clientId for Cloudflare) already exists
    func hasAgent(withURL url: String, clientId: String?) -> Bool {
        return findAgent(withURL: url, clientId: clientId) != nil
    }

    /// Find an existing agent by URL (and clientId for Cloudflare)
    func findAgent(withURL url: String, clientId: String?) -> Agent? {
        let normalizedURL = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        return agents.first { agent in
            let agentURL = agent.url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            if clientId == nil || clientId?.isEmpty == true {
                return agentURL == normalizedURL
            }

            if agentURL == normalizedURL {
                if let storedConfig = try? KeychainManager.retrieve(for: agent.id) {
                    return storedConfig.clientId == clientId
                }
            }
            return false
        }
    }

    func addAgent(config: ConnectionConfig, agentId: String, name: String) throws {
        try addAgent(config: config, agentId: agentId, name: name, bridgeAgentId: nil)
    }

    func addAgent(config: ConnectionConfig, agentId: String, name: String, bridgeAgentId: String?) throws {
        try config.validate()

        // Save credentials to Keychain
        try KeychainManager.save(config: config, for: agentId)

        // Add agent to CoreData
        repository.addAgent(agentId: agentId, name: name, url: config.url, protocolVersion: config.protocolVersion)

        // Set bridgeAgentId if provided
        if let bridgeAgentId = bridgeAgentId,
           let entity = repository.getAgentEntity(agentId: agentId) {
            entity.bridgeAgentId = bridgeAgentId
            repository.updateAgent(entity)
        }

        // Create conversation
        conversations[agentId] = Conversation(agentId: agentId)

        print("✅ AgentManager: Added agent \(name) (\(agentId))")
    }

    /// Find an agent by bridge agent ID (stable UUID from bridge used for multi-transport dedup).
    func findAgent(byBridgeAgentId bridgeAgentId: String) -> Agent? {
        return agents.first { $0.bridgeAgentId == bridgeAgentId }
    }

    /// Add or update a transport endpoint for an agent, and persist its credentials.
    /// Returns a user-facing confirmation message.
    @discardableResult
    func addOrUpdateTransportEndpoint(
        agentId: String,
        transport: String,
        config: ConnectionConfig
    ) throws -> String {
        let existingEndpoints = repository.getAgentEntity(agentId: agentId)?
            .endpoints as? Set<TransportEndpointEntity> ?? []
        let isUpdate = existingEndpoints.contains { $0.transport == transport }

        // Priority: tailscale-serve(0) > tailscale-ip(1) > cloudflare(2) > local(3)
        let priority: Int16
        switch transport {
        case "tailscale-serve": priority = 0
        case "tailscale-ip":    priority = 1
        case "cloudflare":      priority = 2
        default:                priority = 3  // local
        }

        guard let endpoint = repository.upsertTransportEndpoint(
            agentId: agentId,
            transport: transport,
            url: config.url,
            priority: priority
        ) else {
            throw NSError(domain: "AgentManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to upsert endpoint"])
        }

        // Save transport-specific credentials
        let credentials = TransportCredentials(
            authToken: config.authToken,
            certFingerprint: config.certFingerprint,
            clientId: config.clientId,
            clientSecret: config.clientSecret
        )
        try TransportCredentialManager.save(credentials, for: endpoint.endpointId ?? UUID().uuidString)

        let agentName = agents.first { $0.id == agentId }?.name ?? "agent"
        if isUpdate {
            return "Updated \(transport) for \(agentName)"
        } else {
            return "Added \(transport) to \(agentName)"
        }
    }

    /// Update credentials for an existing agent (when re-scanning QR after bridge restart)
    func updateAgentCredentials(agentId: String, config: ConnectionConfig) async throws {
        try config.validate()

        print("📱 AgentManager: Updating credentials for agent \(agentId)")

        if let client = await clientCache.removeClient(for: agentId) {
            await client.disconnect()
        }

        try KeychainManager.save(config: config, for: agentId)

        repository.clearSessionInfo(agentId: agentId)
        repository.updateConnectionStatus(agentId: agentId, status: .disconnected)

        conversations[agentId] = Conversation(agentId: agentId)

        print("📱 AgentManager: Credentials updated successfully for \(agentId)")
    }

    func removeAgent(agentId: String) async {
        let client = await clientCache.removeClient(for: agentId)

        if let client = client {
            await client.disconnect()
        }

        repository.deleteAgent(agentId: agentId)
        conversations.removeValue(forKey: agentId)
        try? KeychainManager.delete(for: agentId)

        print("🗑️ AgentManager: Removed agent \(agentId)")
    }

    func getClient(for agentId: String) async -> ACPClientWrapper? {
        let startTime = CFAbsoluteTimeGetCurrent()
        print("📱 AgentManager.getClient: START for \(agentId)")

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
        // If the agent has transport endpoints, use multi-endpoint fallback
        if let entity = repository.getAgentEntity(agentId: agentId),
           (entity.endpoints as? Set<TransportEndpointEntity>)?.isEmpty == false {
            let didConnect = await connectAgent(agentId: agentId)
            guard didConnect else { return nil }
            return await clientCache.getClient(for: agentId)
        }

        guard let client = await getClient(for: agentId) else {
            return nil
        }

        if case .connected = client.connectionState {
            client.sessionWasResumed = true
            return client
        }

        let existingSessionId = agents.first(where: { $0.id == agentId })?.activeSessionId
        await client.connect(existingSessionId: existingSessionId)

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
        repository.updateSessionInfo(agentId: agentId, sessionId: sessionId, supportsLoad: supportsLoadSession)
        print("📱 AgentManager: Updated session info for \(agentId): sessionId=\(sessionId ?? "nil"), supportsLoad=\(supportsLoadSession)")
    }

    /// Clear the session for an agent (for "Clear Session" button)
    func clearSession(for agentId: String) async {
        repository.clearSessionInfo(agentId: agentId)
        conversations[agentId] = Conversation(agentId: agentId)

        if let client = await clientCache.removeClient(for: agentId) {
            await client.disconnect()
        }

        print("📱 AgentManager: Cleared session for \(agentId)")
    }

    /// Connect to an agent by trying all its transport endpoints in priority order.
    /// Updates connection status and active endpoint state.
    /// - Returns: `true` if any endpoint connected successfully.
    @discardableResult
    func connectAgent(agentId: String) async -> Bool {
        guard let entity = repository.getAgentEntity(agentId: agentId) else {
            print("❌ AgentManager.connectAgent: Agent not found: \(agentId)")
            return false
        }

        var endpoints = entity.sortedEndpoints
        // Move preferred transport to the front
        if let preferred = entity.preferredTransport,
           let preferredIdx = endpoints.firstIndex(where: { $0.transport == preferred }) {
            let preferredEndpoint = endpoints.remove(at: preferredIdx)
            endpoints.insert(preferredEndpoint, at: 0)
        }

        // Fallback to the legacy single-URL config if no endpoints are registered
        if endpoints.isEmpty {
            return await connectAgentLegacy(agentId: agentId)
        }

        repository.updateConnectionStatus(agentId: agentId, status: .reconnecting)

        for endpoint in endpoints {
            guard let endpointId = endpoint.endpointId, let url = endpoint.url else { continue }
            print("📱 AgentManager.connectAgent: Trying endpoint \(endpoint.transport ?? "?") @ \(url)")

            // Build ConnectionConfig from Keychain credentials for this endpoint
            let credentials = try? TransportCredentialManager.retrieve(for: endpointId)
            let config = ConnectionConfig(
                url: url,
                clientId: credentials?.clientId,
                clientSecret: credentials?.clientSecret,
                authToken: credentials?.authToken,
                certFingerprint: credentials?.certFingerprint
            )

            // Swap client for this endpoint's config
            await clientCache.removeClient(for: agentId)
            let existingSessionId = agents.first { $0.id == agentId }?.activeSessionId
            let client = ACPClientWrapper(config: config, agentId: agentId)
            await clientCache.setClient(client, for: agentId)
            await client.connect(existingSessionId: existingSessionId)

            if case .connected = client.connectionState {
                repository.updateEndpointStatus(endpointId: endpointId, isActive: true)
                repository.updateConnectionStatus(agentId: agentId, status: .connected)
                updateAgentSessionInfo(agentId: agentId, sessionId: client.sessionId, supportsLoadSession: client.supportsLoadSession)
                print("✅ AgentManager.connectAgent: Connected via \(endpoint.transport ?? "?")")
                return true
            } else {
                repository.updateEndpointStatus(endpointId: endpointId, isActive: false)
                print("⚠️ AgentManager.connectAgent: Endpoint \(endpoint.transport ?? "?") failed")
            }
        }

        repository.updateConnectionStatus(agentId: agentId, status: .disconnected)
        print("❌ AgentManager.connectAgent: All endpoints failed for \(agentId)")
        return false
    }

    /// Legacy single-URL connection (for agents without transport endpoints).
    private func connectAgentLegacy(agentId: String) async -> Bool {
        guard let client = await getConnectedClient(for: agentId) else { return false }
        if case .connected = client.connectionState { return true }
        return false
    }

    /// Returns transport endpoints for an agent, sorted by priority.
    func transportEndpoints(for agentId: String) -> [TransportEndpointEntity] {
        return repository.getAgentEntity(agentId: agentId)?.sortedEndpoints ?? []
    }

    /// Returns the name of the currently active transport for an agent, if any.
    func activeTransport(for agentId: String) -> String? {
        return repository.getAgentEntity(agentId: agentId)?
            .sortedEndpoints
            .first(where: { $0.isActive })?
            .transport
    }

    /// Set the user's preferred transport for an agent.
    func setPreferredTransport(agentId: String, transport: String?) {
        guard let entity = repository.getAgentEntity(agentId: agentId) else { return }
        entity.preferredTransport = transport
        repository.updateAgent(entity)
    }

    /// Remove a transport endpoint from an agent.
    func deleteTransportEndpoint(agentId: String, endpointId: String) {
        TransportCredentialManager.delete(for: endpointId)
        repository.deleteTransportEndpoint(endpointId: endpointId)
    }

    func sortAgents() {
        agents.sort { agent1, agent2 in
            let lastActivity1 = conversations[agent1.id]?.lastActivity ?? .distantPast
            let lastActivity2 = conversations[agent2.id]?.lastActivity ?? .distantPast
            return lastActivity1 > lastActivity2
        }
    }
}

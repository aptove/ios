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
    /// ID of the agent whose ChatView is currently visible. Used to suppress unread
    /// count increments for the conversation the user is actively reading.
    @Published var activeChatAgentId: String? = nil
    /// Per-agent bridge mismatch warning messages. Populated when a wrong-bridge
    /// identity error is detected; cleared when the agent reconnects successfully.
    @Published var bridgeMismatchWarnings: [String: String] = [:]

    private let clientCache = ClientCache()
    let repository: AgentRepository
    let messageRepository = MessageRepository()
    private var cancellables = Set<AnyCancellable>()
    private var retryTask: Task<Void, Never>?

    /// Tracks agents currently being connected to prevent duplicate concurrent attempts.
    /// Safe to access without extra locking because AgentManager is @MainActor.
    private var connectingAgents: Set<String> = []

    /// Consecutive failure counts per agent for exponential backoff in the retry loop.
    private var retryFailureCounts: [String: Int] = [:]
    /// Earliest time the retry loop is allowed to attempt each agent again.
    private var retryNotBefore: [String: Date] = [:]
    /// Endpoint IDs that responded with 401 Unauthorized — skipped until re-paired.
    private var invalidCredentialEndpoints: Set<String> = []

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
                // Create conversations for any new agents, loading persisted messages and unread count
                for agent in updatedAgents where self.conversations[agent.id] == nil {
                    let persisted = self.messageRepository.fetchMessages(agentId: agent.id)
                    let storedUnread = UserDefaults.standard.integer(forKey: "unreadCount_\(agent.id)")
                    self.conversations[agent.id] = Conversation(agentId: agent.id, messages: persisted, unreadCount: storedUnread)
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

    /// Start a background timer that retries disconnected agents with exponential backoff.
    ///
    /// Backoff schedule per agent: 30s → 60s → 120s → 240s → 480s → 600s (cap).
    /// An agent that keeps failing (e.g. wrong auth token, bridge not running) backs off
    /// to 10-minute retries instead of hammering every 30 seconds.
    private func startBackgroundRetry() {
        retryTask?.cancel()
        retryTask = Task {
            repeat {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // base interval
                guard !Task.isCancelled else { return }
                let now = Date()
                let disconnected = self.agents.filter { $0.status == .disconnected }
                for agent in disconnected {
                    // Skip if still within the backoff window for this agent
                    if let notBefore = self.retryNotBefore[agent.id], notBefore > now {
                        continue
                    }
                    let agentId = agent.id
                    let success = await self.connectAgent(agentId: agentId)
                    if success {
                        self.retryFailureCounts[agentId] = 0
                        self.retryNotBefore.removeValue(forKey: agentId)
                    } else {
                        let failures = (self.retryFailureCounts[agentId] ?? 0) + 1
                        self.retryFailureCounts[agentId] = failures
                        // 30s, 60s, 120s, 240s, 480s, 600s cap
                        let backoff = min(30.0 * pow(2.0, Double(failures - 1)), 600.0)
                        self.retryNotBefore[agentId] = now.addingTimeInterval(backoff)
                        print("📱 AgentManager: \(agentId) backoff \(Int(backoff))s (failure #\(failures))")
                    }
                }
            } while !Task.isCancelled
        }
    }

    /// Check if an agent with the same URL (and clientId for Cloudflare) already exists
    func hasAgent(withURL url: String, clientId: String?) async -> Bool {
        return await findAgent(withURL: url, clientId: clientId) != nil
    }

    /// Find an existing agent by URL (and clientId for Cloudflare).
    /// Keychain reads run off the main thread via async variants.
    func findAgent(withURL url: String, clientId: String?) async -> Agent? {
        let normalizedURL = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        for agent in agents {
            let agentURL = agent.url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            if clientId == nil || clientId?.isEmpty == true {
                if agentURL == normalizedURL { return agent }
                continue
            }

            if agentURL == normalizedURL {
                if let storedConfig = try? await KeychainManager.retrieveAsync(for: agent.id) {
                    if storedConfig.clientId == clientId { return agent }
                }
            }
        }
        return nil
    }

    func addAgent(config: ConnectionConfig, agentId: String, name: String) async throws {
        try await addAgent(config: config, agentId: agentId, name: name, bridgeAgentId: nil)
    }

    func addAgent(config: ConnectionConfig, agentId: String, name: String, bridgeAgentId: String?) async throws {
        try config.validate()

        // Save credentials to Keychain off the main thread
        try await KeychainManager.saveAsync(config: config, for: agentId)

        // Add agent to CoreData
        repository.addAgent(agentId: agentId, name: name, url: config.url, protocolVersion: config.protocolVersion)

        // Set bridgeAgentId and cwd
        if let entity = repository.getAgentEntity(agentId: agentId) {
            if let bridgeAgentId = bridgeAgentId {
                entity.bridgeAgentId = bridgeAgentId
            }
            entity.cwd = config.cwd
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

    /// Find an agent by bridge agent ID AND working directory.
    ///
    /// Two bridge instances can accidentally end up with the same agent_id (e.g. when the
    /// user copies a config or runs a second bridge in a directory that already has a
    /// .aptove/ folder). Using cwd as a secondary discriminator ensures they are
    /// treated as separate agents rather than being merged via the multi-transport path.
    ///
    /// Falls back to ID-only matching when either cwd is empty (old bridge versions that
    /// did not include cwd in the QR code).
    func findAgent(byBridgeAgentId bridgeAgentId: String, cwd: String) -> Agent? {
        guard !cwd.isEmpty else {
            return findAgent(byBridgeAgentId: bridgeAgentId)
        }
        guard let entity = repository.findAgentEntityByBridgeId(bridgeAgentId) else { return nil }
        // If both sides have a non-empty cwd and they differ, this is a different project.
        if !entity.cwd.isEmpty, entity.cwd != cwd {
            return nil
        }
        return entity.toModel()
    }

    /// Add or update a transport endpoint for an agent, and persist its credentials.
    /// Returns a user-facing confirmation message.
    @discardableResult
    func addOrUpdateTransportEndpoint(
        agentId: String,
        transport: String,
        config: ConnectionConfig
    ) async throws -> String {
        let existingEndpoints = repository.getAgentEntity(agentId: agentId)?
            .endpoints as? Set<TransportEndpointEntity> ?? []
        let isUpdate = existingEndpoints.contains { $0.transport == transport }

        // Priority: tailscale-serve(0) > tailscale-ip(1) > enterprise plugins(2) > local(3)
        let priority: Int16
        switch transport {
        case "tailscale-serve": priority = 0
        case "tailscale-ip":    priority = 1
        default:
            // Enterprise transports registered in FeatureRegistry get higher priority than local
            priority = FeatureRegistry.shared.provider(forTransport: transport) != nil ? 2 : 3
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
            clientSecret: config.clientSecret,
            pushRelayUrl: config.pushRelayUrl
        )
        try await TransportCredentialManager.saveAsync(credentials, for: endpoint.endpointId ?? UUID().uuidString)

        // Update cwd from the pairing response
        if let entity = repository.getAgentEntity(agentId: agentId) {
            entity.cwd = config.cwd
            repository.updateAgent(entity)
        }

        let agentName = agents.first { $0.id == agentId }?.name ?? "agent"
        if isUpdate {
            return "Updated \(transport) for \(agentName)"
        } else {
            return "Added \(transport) to \(agentName)"
        }
    }

    /// After pairing one transport, propagate the new auth token and push relay URL to ALL
    /// other endpoints for this agent. Since auth_token is bridge-wide (not per-transport),
    /// all endpoints must use the same token. Also clears any invalid-credential flags so
    /// the retry loop resumes attempting previously-failing endpoints.
    func updateAuthTokenForOtherEndpoints(
        agentId: String,
        excludingTransport: String,
        newAuthToken: String,
        pushRelayUrl: String?
    ) async {
        let endpoints = repository.getAgentEntity(agentId: agentId)?
            .endpoints as? Set<TransportEndpointEntity> ?? []
        for endpoint in endpoints {
            guard let endpointId = endpoint.endpointId,
                  endpoint.transport != excludingTransport else { continue }
            guard var credentials = try? await TransportCredentialManager.retrieveAsync(for: endpointId) else { continue }
            credentials = TransportCredentials(
                authToken: newAuthToken,
                certFingerprint: credentials.certFingerprint,
                clientId: credentials.clientId,
                clientSecret: credentials.clientSecret,
                pushRelayUrl: pushRelayUrl ?? credentials.pushRelayUrl
            )
            try? await TransportCredentialManager.saveAsync(credentials, for: endpointId)
            invalidCredentialEndpoints.remove(endpointId)
            print("📱 AgentManager: Updated auth token for endpoint \(endpoint.transport ?? "?") of agent \(agentId)")
        }
    }

    /// Update credentials for an existing agent (when re-scanning QR after bridge restart)
    func updateAgentCredentials(agentId: String, config: ConnectionConfig) async throws {
        try config.validate()

        print("📱 AgentManager: Updating credentials for agent \(agentId)")

        if let client = await clientCache.removeClient(for: agentId) {
            await client.disconnect()
        }

        try await KeychainManager.saveAsync(config: config, for: agentId)

        // Update cwd from the new config
        if let entity = repository.getAgentEntity(agentId: agentId) {
            entity.cwd = config.cwd
            repository.updateAgent(entity)
        }

        repository.clearSessionInfo(agentId: agentId)
        repository.updateConnectionStatus(agentId: agentId, status: .disconnected)

        conversations[agentId] = Conversation(agentId: agentId)
        messageRepository.deleteMessages(agentId: agentId)

        print("📱 AgentManager: Credentials updated successfully for \(agentId)")
    }

    func removeAgent(agentId: String) async {
        let client = await clientCache.removeClient(for: agentId)

        if let client = client {
            await client.disconnect()
        }

        repository.deleteAgent(agentId: agentId)
        conversations.removeValue(forKey: agentId)
        try? await KeychainManager.deleteAsync(for: agentId)

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
        guard let config = try? await KeychainManager.retrieveAsync(for: agentId) else {
            print("❌ AgentManager.getClient: Keychain FAILED (\(Int((CFAbsoluteTimeGetCurrent() - keychainStart) * 1000))ms)")
            return nil
        }
        print("📱 AgentManager.getClient: Keychain retrieved (\(Int((CFAbsoluteTimeGetCurrent() - keychainStart) * 1000))ms)")

        let existingSessionId = agents.first(where: { $0.id == agentId })?.activeSessionId
        if let sessionId = existingSessionId {
            print("📱 AgentManager.getClient: Found existing session ID: \(sessionId)")
        }

        let initStart = CFAbsoluteTimeGetCurrent()
        let versionMode = agents.first(where: { $0.id == agentId })?.acpVersionMode ?? .auto
        let client = ACPClientWrapper(config: config, agentId: agentId, versionMode: versionMode)
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

    /// Persist a newly-learned bridge identity for an agent that had no stored bridgeAgentId.
    /// Called once per agent lifetime on first connect after the identity feature was deployed.
    private func persistBridgeIdentity(agentId: String, bridgeAgentId: String, cwd: String) {
        guard let entity = repository.getAgentEntity(agentId: agentId) else { return }
        entity.bridgeAgentId = bridgeAgentId
        entity.cwd = cwd
        repository.updateAgent(entity)
        // Update in-memory model so UI and retry logic reflect the new bridgeAgentId.
        if let idx = agents.firstIndex(where: { $0.id == agentId }) {
            agents[idx].bridgeAgentId = bridgeAgentId
        }
        print("📚 AgentManager: Learned bridge identity for \(agentId): bridgeAgentId=\(bridgeAgentId), cwd=\(cwd)")
    }

    /// Clear the session for an agent (for "Clear Session" button)
    func clearSession(for agentId: String) async {
        repository.clearSessionInfo(agentId: agentId)
        conversations[agentId] = Conversation(agentId: agentId)
        messageRepository.deleteMessages(agentId: agentId)

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
        // Guard against concurrent connection attempts for the same agent.
        // Because AgentManager is @MainActor, this Set is accessed serially between
        // suspension points, so no additional locking is needed.
        guard !connectingAgents.contains(agentId) else {
            print("📱 AgentManager.connectAgent: Already connecting to \(agentId), skipping duplicate")
            return false
        }
        connectingAgents.insert(agentId)
        defer { connectingAgents.remove(agentId) }

        // If a live client is already connected, skip the reconnect.
        if let existingClient = await clientCache.getClient(for: agentId),
           case .connected = existingClient.connectionState {
            print("📱 AgentManager.connectAgent: Agent \(agentId) already connected, skipping")
            return true
        }

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
            if invalidCredentialEndpoints.contains(endpointId) {
                print("🔒 AgentManager.connectAgent: Skipping \(endpoint.transport ?? "?") — credentials invalid, re-pair required")
                continue
            }
            print("📱 AgentManager.connectAgent: Trying endpoint \(endpoint.transport ?? "?") @ \(url)")

            // Build ConnectionConfig from Keychain credentials for this endpoint (off main thread)
            let credentials = try? await TransportCredentialManager.retrieveAsync(for: endpointId)
            let config = ConnectionConfig(
                url: url,
                clientId: credentials?.clientId,
                clientSecret: credentials?.clientSecret,
                authToken: credentials?.authToken,
                certFingerprint: credentials?.certFingerprint,
                cwd: entity.cwd,
                pushRelayUrl: credentials?.pushRelayUrl
            )

            // Swap client for this endpoint's config
            _ = await clientCache.removeClient(for: agentId)
            let existingSessionId = agents.first { $0.id == agentId }?.activeSessionId
            let versionMode = agents.first(where: { $0.id == agentId })?.acpVersionMode ?? .auto
            let client = ACPClientWrapper(config: config, agentId: agentId, expectedBridgeAgentId: entity.bridgeAgentId, versionMode: versionMode)

            // Trigger multi-transport reconnect when the WebSocket closes unexpectedly.
            client.onUnexpectedDisconnect = { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    print("📱 AgentManager: Transport closed unexpectedly for \(agentId) — retrying all transports")
                    _ = await self.connectAgent(agentId: agentId)
                }
            }

            // Learn bridge identity for agents paired before the bridgeAgentId feature.
            // Persists bridgeAgentId and cwd so future connections can validate identity.
            client.onLearnBridgeIdentity = { [weak self] bridgeAgentId, bridgeCwd in
                guard let self else { return }
                self.persistBridgeIdentity(agentId: agentId, bridgeAgentId: bridgeAgentId, cwd: bridgeCwd)
            }

            client.onColdStartReplayComplete = { [weak self, weak client] text in
                guard let self else { return }
                Task { @MainActor in
                    let preview = Message(text: text, sender: .agent, status: .sent, type: .text)
                    // Persist to CoreData so preview survives app restart
                    if let entity = self.repository.getAgentEntity(agentId: agentId) {
                        let existing = self.conversations[agentId]?.messages ?? []
                        self.messageRepository.saveMessages(existing + [preview], agentId: agentId, agent: entity)
                    }
                    // Update in-memory conversation for immediate AgentListView update
                    self.conversations[agentId]?.messages.append(preview)
                    // Clear pendingBufferedResponse so ChatViewModel doesn't double-add it
                    client?.pendingBufferedResponse = nil
                    // Increment unread badge (no-op if ChatView for this agent is currently open)
                    self.incrementUnreadCount(agentId: agentId)
                }
            }

            await clientCache.setClient(client, for: agentId)
            await client.connect(existingSessionId: existingSessionId)

            // If the bridge rejected us due to identity mismatch, back off for 5 minutes
            // so the retry loop doesn't repeatedly reconnect and immediately disconnect.
            if case .error(let msg) = client.connectionState, msg.hasPrefix("wrongBridge:") {
                repository.updateConnectionStatus(agentId: agentId, status: .disconnected)
                retryNotBefore[agentId] = Date().addingTimeInterval(300)
                bridgeMismatchWarnings[agentId] = client.connectionMessage
                return false
            }

            // If the bridge rejected us with 401 (stale token), stop retrying this endpoint
            // for 24 hours. The only recovery is a fresh QR scan to re-pair.
            if case .error(let msg) = client.connectionState, msg.hasPrefix("unauthorized:") {
                print("🔒 AgentManager.connectAgent: 401 on endpoint \(endpoint.transport ?? "?") — backing off 24h")
                repository.updateConnectionStatus(agentId: agentId, status: .disconnected)
                invalidCredentialEndpoints.insert(endpointId)
                // Skip remaining endpoints — they all share the same token for this bridge
                break
            }

            if case .connected = client.connectionState {
                repository.updateEndpointStatus(endpointId: endpointId, isActive: true)
                repository.updateConnectionStatus(agentId: agentId, status: .connected)
                updateAgentSessionInfo(agentId: agentId, sessionId: client.sessionId, supportsLoadSession: client.supportsLoadSession)
                // Remember the working transport so next reconnect tries it first,
                // skipping endpoints that are currently unreachable.
                if entity.preferredTransport != endpoint.transport {
                    setPreferredTransport(agentId: agentId, transport: endpoint.transport)
                }
                print("✅ AgentManager.connectAgent: Connected via \(endpoint.transport ?? "?")")
                // Clear backoff state so the retry loop picks this agent up immediately if it disconnects again
                retryFailureCounts[agentId] = 0
                retryNotBefore.removeValue(forKey: agentId)
                bridgeMismatchWarnings.removeValue(forKey: agentId)
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

    /// Disconnect the active client for an agent and mark it as disconnected.
    /// Does NOT attempt reconnect — call `connectAgent` afterwards if needed.
    func disconnectAgent(agentId: String) async {
        if let client = await clientCache.removeClient(for: agentId) {
            await client.disconnect()
        }
        repository.updateConnectionStatus(agentId: agentId, status: .disconnected)
    }

    /// Disconnect all currently connected agents.
    ///
    /// Called when the app enters background so the bridge detects the closed
    /// WebSocket and sends a push notification. `disconnect()` cancels the
    /// transport observer first, so no spurious auto-reconnect fires.
    func disconnectAll() async {
        let connectedIds = agents
            .filter { $0.status == .connected || $0.status == .reconnecting }
            .map { $0.id }
        print("🌙 [push-dbg] AgentManager: disconnecting \(connectedIds.count) agent(s) for background")
        for agentId in connectedIds {
            await disconnectAgent(agentId: agentId)
        }
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

    /// Set the ACP protocol version mode for an agent.
    /// The change takes effect on the next connection attempt.
    func setVersionMode(agentId: String, mode: ACPVersionMode) {
        guard let entity = repository.getAgentEntity(agentId: agentId) else { return }
        entity.acpVersionMode = mode.rawValue
        repository.updateAgent(entity)
    }

    /// Remove a transport endpoint from an agent.
    func deleteTransportEndpoint(agentId: String, endpointId: String) {
        TransportCredentialManager.delete(for: endpointId)
        repository.deleteTransportEndpoint(endpointId: endpointId)
    }

    func renameAgent(agentId: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        repository.renameAgent(agentId: agentId, newName: trimmed)
    }

    func sortAgents() {
        agents.sort { agent1, agent2 in
            let lastActivity1 = conversations[agent1.id]?.lastActivity ?? .distantPast
            let lastActivity2 = conversations[agent2.id]?.lastActivity ?? .distantPast
            return lastActivity1 > lastActivity2
        }
    }

    /// Increment the unread badge count for an agent. No-op if the user is currently
    /// viewing that agent's chat (activeChatAgentId == agentId).
    func incrementUnreadCount(agentId: String, by count: Int = 1) {
        guard activeChatAgentId != agentId else { return }
        let current = conversations[agentId]?.unreadCount ?? 0
        conversations[agentId]?.unreadCount = current + count
        UserDefaults.standard.set(current + count, forKey: "unreadCount_\(agentId)")
    }

    /// Clear the unread badge count for an agent (called when ChatView opens).
    func clearUnreadCount(agentId: String) {
        conversations[agentId]?.unreadCount = 0
        UserDefaults.standard.removeObject(forKey: "unreadCount_\(agentId)")
    }

    /// Correct a voice transcript using the AI agent for the given agent.
    func correctVoiceTranscript(_ rawTranscript: String, for agentId: String, language: String) async -> String {
        guard let client = await getConnectedClient(for: agentId) else { return rawTranscript }
        return await client.correctTranscript(rawTranscript, language: language)
    }

    /// Send a memory entry to the bridge for the given agent.
    func sendMemoryEntry(_ text: String, for agentId: String) async {
        guard let client = await getConnectedClient(for: agentId) else { return }
        await client.sendMemoryEntry(text)
    }
}

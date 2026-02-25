//  AgentRepository.swift
//

import Foundation
import CoreData
import Combine

/// Repository for Agent data access, matching Android's AgentRepository API
class AgentRepository {
    private let coreDataStack: CoreDataStack
    private var cancellables = Set<AnyCancellable>()

    /// Publisher for reactive agent list updates (CoreData entities)
    @Published private(set) var agentEntities: [AgentEntity] = []

    init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
        setupObserver()
    }

    // MARK: - Reactive Queries

    /// Observe all agents with reactive updates (returns Agent structs for backward compatibility)
    func observeAgents() -> AnyPublisher<[Agent], Never> {
        return $agentEntities
            .map { $0.map { $0.toModel() } }
            .eraseToAnyPublisher()
    }

    /// Observe a single agent by ID
    func observeAgent(agentId: String) -> AnyPublisher<Agent?, Never> {
        return $agentEntities
            .map { entities in entities.first { $0.agentId == agentId }?.toModel() }
            .eraseToAnyPublisher()
    }

    // MARK: - CRUD Operations

    /// Fetch all agents as Agent structs (synchronous)
    func fetchAgents() -> [Agent] {
        return fetchAgentEntities().map { $0.toModel() }
    }

    /// Fetch all AgentEntity objects (synchronous)
    func fetchAgentEntities() -> [AgentEntity] {
        let request = AgentEntity.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \AgentEntity.lastConnectedAt, ascending: false),
            NSSortDescriptor(keyPath: \AgentEntity.createdAt, ascending: false)
        ]

        do {
            return try coreDataStack.viewContext.fetch(request)
        } catch {
            print("❌ AgentRepository: Failed to fetch agents: \(error)")
            return []
        }
    }

    /// Add a new agent
    func addAgent(agentId: String, name: String, url: String, protocolVersion: String) {
        let context = coreDataStack.viewContext
        let _ = AgentEntity(context: context,
                         agentId: agentId,
                         name: name,
                         url: url,
                         protocolVersion: protocolVersion)

        saveContext(context)
        refreshAgents()
    }

    /// Update an existing agent entity
    func updateAgent(_ entity: AgentEntity) {
        saveContext(coreDataStack.viewContext)
        refreshAgents()
    }

    /// Delete agent by ID
    func deleteAgent(agentId: String) {
        let request = AgentEntity.fetchRequest()
        request.predicate = NSPredicate(format: "agentId == %@", agentId)

        do {
            let results = try coreDataStack.viewContext.fetch(request)
            results.forEach { coreDataStack.viewContext.delete($0) }
            saveContext(coreDataStack.viewContext)
            refreshAgents()
        } catch {
            print("❌ AgentRepository: Failed to delete agent: \(error)")
        }
    }

    /// Find agent by URL (returns Agent struct)
    func findAgentByUrl(_ url: String) -> Agent? {
        return findAgentEntityByUrl(url)?.toModel()
    }

    /// Find agent entity by URL
    func findAgentEntityByUrl(_ url: String) -> AgentEntity? {
        let request = AgentEntity.fetchRequest()
        let normalizedUrl = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        request.predicate = NSPredicate(format: "url CONTAINS[cd] %@", normalizedUrl)
        request.fetchLimit = 1

        do {
            let results = try coreDataStack.viewContext.fetch(request)
            return results.first
        } catch {
            print("❌ AgentRepository: Failed to find agent by URL: \(error)")
            return nil
        }
    }

    /// Get agent entity by ID
    func getAgentEntity(agentId: String) -> AgentEntity? {
        let request = AgentEntity.fetchRequest()
        request.predicate = NSPredicate(format: "agentId == %@", agentId)
        request.fetchLimit = 1

        do {
            let results = try coreDataStack.viewContext.fetch(request)
            return results.first
        } catch {
            print("❌ AgentRepository: Failed to get agent: \(error)")
            return nil
        }
    }

    // MARK: - Session Management

    /// Update session info for an agent
    func updateSessionInfo(agentId: String, sessionId: String?, supportsLoad: Bool) {
        guard let entity = getAgentEntity(agentId: agentId) else {
            print("❌ AgentRepository: Agent not found for session update: \(agentId)")
            return
        }

        entity.activeSessionId = sessionId
        entity.sessionStartedAt = sessionId != nil ? Date() : nil
        entity.supportsLoadSession = supportsLoad

        saveContext(coreDataStack.viewContext)
        refreshAgents()

        print("📝 AgentRepository: Updated session info for \(agentId): sessionId=\(sessionId ?? "nil"), supportsLoad=\(supportsLoad)")
    }

    /// Clear session info for an agent
    func clearSessionInfo(agentId: String) {
        guard let entity = getAgentEntity(agentId: agentId) else {
            print("❌ AgentRepository: Agent not found for session clear: \(agentId)")
            return
        }

        entity.activeSessionId = nil
        entity.sessionStartedAt = nil

        saveContext(coreDataStack.viewContext)
        refreshAgents()

        print("🗑️ AgentRepository: Cleared session info for \(agentId)")
    }

    // MARK: - Connection Status

    /// Update connection status for an agent
    func updateConnectionStatus(agentId: String, status: ConnectionStatus) {
        guard let entity = getAgentEntity(agentId: agentId) else {
            print("❌ AgentRepository: Agent not found for status update: \(agentId)")
            return
        }

        entity.status = status
        if status == .connected {
            entity.lastConnectedAt = Date()
        }

        saveContext(coreDataStack.viewContext)
        refreshAgents()
    }

    // MARK: - Transport Endpoint Operations

    /// Find an agent entity by bridge agent ID (for deduplication).
    func findAgentEntityByBridgeId(_ bridgeAgentId: String) -> AgentEntity? {
        let request = AgentEntity.fetchRequest()
        request.predicate = NSPredicate(format: "bridgeAgentId == %@", bridgeAgentId)
        request.fetchLimit = 1
        do {
            return try coreDataStack.viewContext.fetch(request).first
        } catch {
            print("❌ AgentRepository: Failed to find agent by bridgeAgentId: \(error)")
            return nil
        }
    }

    /// Add or update a transport endpoint for an agent.
    /// If an endpoint with the same transport already exists for this agent, it is updated.
    func upsertTransportEndpoint(
        agentId: String,
        transport: String,
        url: String,
        priority: Int16
    ) -> TransportEndpointEntity? {
        guard let agentEntity = getAgentEntity(agentId: agentId) else {
            print("❌ AgentRepository: Agent not found for endpoint upsert: \(agentId)")
            return nil
        }
        let context = coreDataStack.viewContext

        // Look for existing endpoint with same transport
        let existingEndpoints = agentEntity.endpoints as? Set<TransportEndpointEntity> ?? []
        if let existing = existingEndpoints.first(where: { $0.transport == transport }) {
            existing.url = url
            existing.priority = priority
            saveContext(context)
            refreshAgents()
            return existing
        }

        // Create new endpoint
        let endpoint = TransportEndpointEntity(
            context: context,
            endpointId: UUID().uuidString,
            transport: transport,
            url: url,
            priority: priority
        )
        endpoint.agent = agentEntity
        agentEntity.addToEndpoints(endpoint)
        saveContext(context)
        refreshAgents()
        return endpoint
    }

    /// Delete a transport endpoint by ID.
    func deleteTransportEndpoint(endpointId: String) {
        let request = TransportEndpointEntity.fetchRequest()
        request.predicate = NSPredicate(format: "endpointId == %@", endpointId)
        do {
            let results = try coreDataStack.viewContext.fetch(request)
            results.forEach { coreDataStack.viewContext.delete($0) }
            saveContext(coreDataStack.viewContext)
            refreshAgents()
        } catch {
            print("❌ AgentRepository: Failed to delete endpoint: \(error)")
        }
    }

    /// Mark an endpoint as active/inactive.
    func updateEndpointStatus(endpointId: String, isActive: Bool) {
        let request = TransportEndpointEntity.fetchRequest()
        request.predicate = NSPredicate(format: "endpointId == %@", endpointId)
        do {
            let results = try coreDataStack.viewContext.fetch(request)
            if let endpoint = results.first {
                endpoint.isActive = isActive
                if isActive { endpoint.lastConnectedAt = Date() }
                saveContext(coreDataStack.viewContext)
                refreshAgents()
            }
        } catch {
            print("❌ AgentRepository: Failed to update endpoint status: \(error)")
        }
    }

    // MARK: - Private Helpers

    private func setupObserver() {
        refreshAgents()

        NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: coreDataStack.viewContext)
            .sink { [weak self] _ in
                self?.refreshAgents()
            }
            .store(in: &cancellables)
    }

    private func refreshAgents() {
        agentEntities = fetchAgentEntities()
    }

    private func saveContext(_ context: NSManagedObjectContext) {
        guard context.hasChanges else { return }

        do {
            try context.save()
            print("✅ AgentRepository: Context saved successfully")
        } catch {
            print("❌ AgentRepository: Failed to save context: \(error)")
        }
    }
}

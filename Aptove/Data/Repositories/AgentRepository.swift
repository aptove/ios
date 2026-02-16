//  AgentRepository.swift
//

import Foundation
import CoreData
import Combine

/// Repository for Agent data access, matching Android's AgentRepository API
class AgentRepository {
    private let coreDataStack: CoreDataStack
    private var cancellables = Set<AnyCancellable>()

    /// Publisher for reactive agent list updates
    @Published private(set) var agents: [Agent] = []

    init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
        setupObserver()
    }

    // MARK: - Reactive Queries

    /// Observe all agents with reactive updates
    func observeAgents() -> AnyPublisher<[Agent], Never> {
        return $agents.eraseToAnyPublisher()
    }

    /// Observe a single agent by ID
    func observeAgent(agentId: String) -> AnyPublisher<Agent?, Never> {
        return $agents
            .map { agents in agents.first { $0.agentId == agentId } }
            .eraseToAnyPublisher()
    }

    // MARK: - CRUD Operations

    /// Fetch all agents (synchronous)
    func fetchAgents() -> [Agent] {
        let request = Agent.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Agent.lastConnectedAt, ascending: false),
            NSSortDescriptor(keyPath: \Agent.createdAt, ascending: false)
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
        let agent = Agent(context: context,
                         agentId: agentId,
                         name: name,
                         url: url,
                         protocolVersion: protocolVersion)

        saveContext(context)
        refreshAgents()
    }

    /// Update an existing agent
    func updateAgent(_ agent: Agent) {
        saveContext(coreDataStack.viewContext)
        refreshAgents()
    }

    /// Delete agent by ID
    func deleteAgent(agentId: String) {
        let request = Agent.fetchRequest()
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

    /// Find agent by URL
    func findAgentByUrl(_ url: String) -> Agent? {
        let request = Agent.fetchRequest()
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

    /// Get agent by ID
    func getAgent(agentId: String) -> Agent? {
        let request = Agent.fetchRequest()
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
        guard let agent = getAgent(agentId: agentId) else {
            print("❌ AgentRepository: Agent not found for session update: \(agentId)")
            return
        }

        agent.activeSessionId = sessionId
        agent.sessionStartedAt = sessionId != nil ? Date() : nil
        agent.supportsLoadSession = supportsLoad

        saveContext(coreDataStack.viewContext)
        refreshAgents()

        print("📝 AgentRepository: Updated session info for \(agentId): sessionId=\(sessionId ?? "nil"), supportsLoad=\(supportsLoad)")
    }

    /// Clear session info for an agent
    func clearSessionInfo(agentId: String) {
        guard let agent = getAgent(agentId: agentId) else {
            print("❌ AgentRepository: Agent not found for session clear: \(agentId)")
            return
        }

        agent.activeSessionId = nil
        agent.sessionStartedAt = nil

        saveContext(coreDataStack.viewContext)
        refreshAgents()

        print("🗑️ AgentRepository: Cleared session info for \(agentId)")
    }

    // MARK: - Connection Status

    /// Update connection status for an agent
    func updateConnectionStatus(agentId: String, status: ConnectionStatus) {
        guard let agent = getAgent(agentId: agentId) else {
            print("❌ AgentRepository: Agent not found for status update: \(agentId)")
            return
        }

        agent.status = status
        if status == .connected {
            agent.lastConnectedAt = Date()
        }

        saveContext(coreDataStack.viewContext)
        refreshAgents()
    }

    // MARK: - Private Helpers

    private func setupObserver() {
        // Perform initial fetch
        refreshAgents()

        // Observe CoreData changes
        NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: coreDataStack.viewContext)
            .sink { [weak self] _ in
                self?.refreshAgents()
            }
            .store(in: &cancellables)
    }

    private func refreshAgents() {
        agents = fetchAgents()
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

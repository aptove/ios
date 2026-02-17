import XCTest
import CoreData
import Combine
@testable import Aptove

final class AgentRepositoryTests: XCTestCase {

    var stack: CoreDataStack!
    var repository: AgentRepository!
    var cancellables = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        stack = CoreDataStack.makeInMemory()
        repository = AgentRepository(coreDataStack: stack)
    }

    override func tearDown() {
        cancellables.removeAll()
        repository = nil
        stack = nil
        super.tearDown()
    }

    // MARK: - CRUD Tests

    func testAddAgent() {
        repository.addAgent(agentId: "agent-1", name: "Test Agent", url: "wss://localhost:3001", protocolVersion: "1")

        let agents = repository.fetchAgents()
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents.first?.id, "agent-1")
        XCTAssertEqual(agents.first?.name, "Test Agent")
        XCTAssertEqual(agents.first?.url, "wss://localhost:3001")
    }

    func testDeleteAgent() {
        repository.addAgent(agentId: "agent-1", name: "Test Agent", url: "wss://localhost:3001", protocolVersion: "1")
        XCTAssertEqual(repository.fetchAgents().count, 1)

        repository.deleteAgent(agentId: "agent-1")
        XCTAssertEqual(repository.fetchAgents().count, 0)
    }

    func testDeleteNonExistentAgent() {
        // Should not crash
        repository.deleteAgent(agentId: "nonexistent")
        XCTAssertEqual(repository.fetchAgents().count, 0)
    }

    func testFindAgentByUrl() {
        repository.addAgent(agentId: "agent-1", name: "Test Agent", url: "wss://localhost:3001", protocolVersion: "1")

        let found = repository.findAgentByUrl("wss://localhost:3001")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, "agent-1")
    }

    func testFindAgentByUrlNotFound() {
        let found = repository.findAgentByUrl("wss://other:3002")
        XCTAssertNil(found)
    }

    // MARK: - Session Management Tests

    func testUpdateSessionInfo() {
        repository.addAgent(agentId: "agent-1", name: "Test Agent", url: "wss://localhost:3001", protocolVersion: "1")

        repository.updateSessionInfo(agentId: "agent-1", sessionId: "session-abc", supportsLoad: true)

        let agents = repository.fetchAgents()
        XCTAssertEqual(agents.first?.activeSessionId, "session-abc")
        XCTAssertEqual(agents.first?.supportsLoadSession, true)
        XCTAssertNotNil(agents.first?.sessionStartedAt)
    }

    func testClearSessionInfo() {
        repository.addAgent(agentId: "agent-1", name: "Test Agent", url: "wss://localhost:3001", protocolVersion: "1")
        repository.updateSessionInfo(agentId: "agent-1", sessionId: "session-abc", supportsLoad: true)

        repository.clearSessionInfo(agentId: "agent-1")

        let agents = repository.fetchAgents()
        XCTAssertNil(agents.first?.activeSessionId)
        XCTAssertNil(agents.first?.sessionStartedAt)
    }

    func testUpdateSessionInfoForNonExistentAgent() {
        // Should not crash
        repository.updateSessionInfo(agentId: "nonexistent", sessionId: "session-abc", supportsLoad: false)
    }

    // MARK: - Connection Status Tests

    func testUpdateConnectionStatus() {
        repository.addAgent(agentId: "agent-1", name: "Test Agent", url: "wss://localhost:3001", protocolVersion: "1")

        repository.updateConnectionStatus(agentId: "agent-1", status: .connected)

        let entity = repository.getAgentEntity(agentId: "agent-1")
        XCTAssertEqual(entity?.status, .connected)
        XCTAssertNotNil(entity?.lastConnectedAt)
    }

    func testDisconnectStatusDoesNotSetLastConnectedAt() {
        repository.addAgent(agentId: "agent-1", name: "Test Agent", url: "wss://localhost:3001", protocolVersion: "1")

        repository.updateConnectionStatus(agentId: "agent-1", status: .disconnected)

        let entity = repository.getAgentEntity(agentId: "agent-1")
        XCTAssertNil(entity?.lastConnectedAt)
    }

    // MARK: - Reactive Publisher Tests

    func testObserveAgentsEmitsInitialValue() {
        let expectation = expectation(description: "Initial agents emitted")

        repository.observeAgents()
            .first()
            .sink { agents in
                XCTAssertEqual(agents.count, 0)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        wait(for: [expectation], timeout: 1.0)
    }

    func testObserveAgentsEmitsOnAdd() {
        let expectation = expectation(description: "Agent add emitted")

        repository.observeAgents()
            .dropFirst() // skip initial empty
            .first()
            .sink { agents in
                XCTAssertEqual(agents.count, 1)
                XCTAssertEqual(agents.first?.id, "agent-1")
                expectation.fulfill()
            }
            .store(in: &cancellables)

        repository.addAgent(agentId: "agent-1", name: "Test Agent", url: "wss://localhost:3001", protocolVersion: "1")

        wait(for: [expectation], timeout: 1.0)
    }

    func testObserveAgentsEmitsOnDelete() {
        repository.addAgent(agentId: "agent-1", name: "Test Agent", url: "wss://localhost:3001", protocolVersion: "1")

        let expectation = expectation(description: "Agent delete emitted")

        repository.observeAgents()
            .dropFirst() // skip current state
            .first()
            .sink { agents in
                XCTAssertEqual(agents.count, 0)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        repository.deleteAgent(agentId: "agent-1")

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Multiple Agents Tests

    func testAddMultipleAgents() {
        repository.addAgent(agentId: "agent-1", name: "Agent 1", url: "wss://localhost:3001", protocolVersion: "1")
        repository.addAgent(agentId: "agent-2", name: "Agent 2", url: "wss://localhost:3002", protocolVersion: "1")
        repository.addAgent(agentId: "agent-3", name: "Agent 3", url: "wss://localhost:3003", protocolVersion: "1")

        XCTAssertEqual(repository.fetchAgents().count, 3)
    }

    func testDeleteOneOfMultipleAgents() {
        repository.addAgent(agentId: "agent-1", name: "Agent 1", url: "wss://localhost:3001", protocolVersion: "1")
        repository.addAgent(agentId: "agent-2", name: "Agent 2", url: "wss://localhost:3002", protocolVersion: "1")

        repository.deleteAgent(agentId: "agent-1")

        let agents = repository.fetchAgents()
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents.first?.id, "agent-2")
    }
}

import XCTest
import CoreData
@testable import Aptove

final class UserDefaultsMigratorTests: XCTestCase {

    var stack: CoreDataStack!
    var repository: AgentRepository!
    var testUserDefaults: UserDefaults!
    var migrator: UserDefaultsMigrator!

    override func setUp() {
        super.setUp()
        stack = CoreDataStack.makeInMemory()
        repository = AgentRepository(coreDataStack: stack)
        testUserDefaults = UserDefaults(suiteName: "test-migration-\(UUID().uuidString)")!
        migrator = UserDefaultsMigrator(coreDataStack: stack, userDefaults: testUserDefaults, repository: repository)
    }

    override func tearDown() {
        migrator = nil
        testUserDefaults.removePersistentDomain(forName: testUserDefaults.description)
        testUserDefaults = nil
        repository = nil
        stack = nil
        super.tearDown()
    }

    // MARK: - needsMigration Tests

    func testNeedsMigrationWithNoUserDefaultsData() {
        // No data in UserDefaults → no migration needed
        XCTAssertFalse(migrator.needsMigration())
    }

    func testNeedsMigrationWithUserDefaultsDataAndEmptyCoreData() {
        setUserDefaultsAgents([makeLegacyAgent(id: "agent-1", name: "Test")])
        XCTAssertTrue(migrator.needsMigration())
    }

    func testNeedsMigrationFalseIfAlreadyMigrated() {
        setUserDefaultsAgents([makeLegacyAgent(id: "agent-1", name: "Test")])
        testUserDefaults.set(true, forKey: "coredata_migration_complete")
        XCTAssertFalse(migrator.needsMigration())
    }

    func testNeedsMigrationFalseIfCoreDataAlreadyHasData() {
        setUserDefaultsAgents([makeLegacyAgent(id: "agent-1", name: "Test")])
        repository.addAgent(agentId: "agent-1", name: "Test", url: "wss://localhost:3001", protocolVersion: "1")
        XCTAssertFalse(migrator.needsMigration())
    }

    // MARK: - migrate() Tests

    func testMigrateEmptyUserDefaults() {
        XCTAssertThrowsError(try migrator.migrate()) { error in
            guard case MigrationError.noData = error else {
                XCTFail("Expected MigrationError.noData, got \(error)")
                return
            }
        }
    }

    func testMigrateAgentBasicFields() throws {
        setUserDefaultsAgents([makeLegacyAgent(id: "agent-1", name: "My Agent", url: "wss://localhost:3001")])

        try migrator.migrate()

        let agents = repository.fetchAgents()
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents.first?.id, "agent-1")
        XCTAssertEqual(agents.first?.name, "My Agent")
        XCTAssertEqual(agents.first?.url, "wss://localhost:3001")
    }

    func testMigrateMultipleAgents() throws {
        setUserDefaultsAgents([
            makeLegacyAgent(id: "agent-1", name: "Agent 1"),
            makeLegacyAgent(id: "agent-2", name: "Agent 2"),
            makeLegacyAgent(id: "agent-3", name: "Agent 3"),
        ])

        try migrator.migrate()

        XCTAssertEqual(repository.fetchAgents().count, 3)
    }

    func testMigratePreservesSessionId() throws {
        setUserDefaultsAgents([makeLegacyAgent(id: "agent-1", name: "Agent 1")])
        testUserDefaults.set("session-xyz", forKey: "aptove.sessionId.agent-1")

        try migrator.migrate()

        let agents = repository.fetchAgents()
        XCTAssertEqual(agents.first?.activeSessionId, "session-xyz")
        XCTAssertNotNil(agents.first?.sessionStartedAt)
    }

    func testMigrateAgentWithNoSessionId() throws {
        setUserDefaultsAgents([makeLegacyAgent(id: "agent-1", name: "Agent 1")])
        // No session ID stored for this agent

        try migrator.migrate()

        let agents = repository.fetchAgents()
        XCTAssertNil(agents.first?.activeSessionId)
        XCTAssertNil(agents.first?.sessionStartedAt)
    }

    func testMigrateSetsCompletionFlag() throws {
        setUserDefaultsAgents([makeLegacyAgent(id: "agent-1", name: "Agent 1")])

        try migrator.migrate()

        XCTAssertTrue(testUserDefaults.bool(forKey: "coredata_migration_complete"))
    }

    func testMigratePreservesOriginalUserDefaultsData() throws {
        setUserDefaultsAgents([makeLegacyAgent(id: "agent-1", name: "Agent 1")])

        try migrator.migrate()

        // Original data should still be there
        XCTAssertNotNil(testUserDefaults.data(forKey: "agents"))
    }

    // MARK: - Idempotency Tests

    func testMigrateIsIdempotentViaFlag() throws {
        setUserDefaultsAgents([makeLegacyAgent(id: "agent-1", name: "Agent 1")])

        try migrator.migrate()

        // Second call should be a no-op (needsMigration returns false)
        XCTAssertFalse(migrator.needsMigration())
    }

    // MARK: - Rollback Tests

    func testRollback() throws {
        setUserDefaultsAgents([makeLegacyAgent(id: "agent-1", name: "Agent 1")])
        try migrator.migrate()
        XCTAssertFalse(migrator.needsMigration())

        migrator.rollback()

        // After rollback, migration flag is cleared
        // But CoreData has data, so needsMigration returns false (CoreData not empty)
        XCTAssertFalse(migrator.needsMigration())
    }

    // MARK: - Helpers

    private func makeLegacyAgent(id: String, name: String, url: String = "wss://localhost:3001") -> [String: Any] {
        return [
            "id": id,
            "name": name,
            "config": [
                "url": url,
                "version": "1.0.0"
            ]
        ]
    }

    private func setUserDefaultsAgents(_ agents: [[String: Any]]) {
        let data = try! JSONSerialization.data(withJSONObject: agents)
        testUserDefaults.set(data, forKey: "agents")
    }
}

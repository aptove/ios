import XCTest
import CoreData
@testable import Aptove

/// Tests that `bridgeAgentId` is the sole identity key for deduplication.
///
/// The port / URL is irrelevant: two bridges with different agent IDs must always
/// produce two separate iOS agents even if they happen to bind the same port.
final class AgentDedupTests: XCTestCase {

    var stack: CoreDataStack!
    var repository: AgentRepository!

    override func setUp() {
        super.setUp()
        stack = CoreDataStack.makeInMemory()
        repository = AgentRepository(coreDataStack: stack)
    }

    override func tearDown() {
        repository = nil
        stack = nil
        super.tearDown()
    }

    // MARK: - bridgeAgentId uniqueness

    /// The canonical scenario: first bridge stopped, second bridge started in a different
    /// directory but randomly assigned the same port. Must produce a new agent.
    func testDifferentBridgeAgentIdSamePortIsDistinct() {
        // First bridge was running on port 8767
        addEntity(iosId: "ios-1", bridgeId: "bridge-aaa", url: "wss://192.168.1.10:8767", cwd: "/code/project")

        // Second bridge also lands on 8767 (first bridge stopped, port freed)
        let entity = repository.findAgentEntityByBridgeId("bridge-bbb")
        XCTAssertNil(entity,
            "A different bridgeAgentId must not match an existing agent even when the port is identical")
    }

    func testSameBridgeAgentIdSamePortIsSameAgent() {
        addEntity(iosId: "ios-1", bridgeId: "bridge-aaa", url: "wss://192.168.1.10:8767", cwd: "/code/project")

        let entity = repository.findAgentEntityByBridgeId("bridge-aaa")
        XCTAssertNotNil(entity, "Same bridgeAgentId must return the existing agent")
        XCTAssertEqual(entity?.agentId, "ios-1")
    }

    func testSameBridgeAgentIdDifferentPortIsSameAgent() {
        // Multi-transport: same bridge, different transport (local vs tailscale)
        addEntity(iosId: "ios-1", bridgeId: "bridge-aaa", url: "wss://192.168.1.10:8765", cwd: "/code/project")

        let entity = repository.findAgentEntityByBridgeId("bridge-aaa")
        XCTAssertNotNil(entity, "Same bridgeAgentId must match regardless of which port the bridge is using")
        XCTAssertEqual(entity?.agentId, "ios-1")
    }

    func testTwoBridgesWithDifferentIdsBothStoredIndependently() {
        addEntity(iosId: "ios-1", bridgeId: "bridge-aaa", url: "wss://192.168.1.10:8765", cwd: "/code/project-a")
        addEntity(iosId: "ios-2", bridgeId: "bridge-bbb", url: "wss://192.168.1.10:8766", cwd: "/tmp")

        let a = repository.findAgentEntityByBridgeId("bridge-aaa")
        let b = repository.findAgentEntityByBridgeId("bridge-bbb")

        XCTAssertEqual(a?.agentId, "ios-1")
        XCTAssertEqual(b?.agentId, "ios-2")
        XCTAssertNotEqual(a?.agentId, b?.agentId, "Each bridgeAgentId must map to its own iOS agent")
    }

    // MARK: - URL match alone is not sufficient for dedup

    /// Reproduces the exact bug: same URL (same IP + same port), different bridgeAgentId.
    /// The dedup check in QRScannerViewModel uses isSameBridge = (newId == existingId).
    /// This test verifies the input to that check: the entity found by URL has a different
    /// bridgeAgentId, so isSameBridge must be false and a new agent must be created.
    func testSameURLDifferentBridgeAgentIdIsSameBridgeFalse() {
        let sharedURL = "wss://192.168.1.10:8767"
        addEntity(iosId: "ios-1", bridgeId: "bridge-aaa", url: sharedURL, cwd: "/code/project")

        // Simulate what findAgent(withURL:) returns
        let existingBridgeId = repository.findAgentByUrl(sharedURL)?.bridgeAgentId

        // The new scan comes in with a different bridgeAgentId
        let newBridgeId = "bridge-bbb"

        // Replicate the isSameBridge computation from QRScannerViewModel.connectWithConfig
        let isSameBridge: Bool
        if let newId = newBridgeId as String?,
           let existingId = existingBridgeId,
           !newId.isEmpty, !existingId.isEmpty {
            isSameBridge = (newId == existingId)
        } else {
            isSameBridge = true // legacy fallback (no bridgeAgentId on file)
        }

        XCTAssertFalse(isSameBridge,
            "URL match with mismatched bridgeAgentId must not be treated as the same bridge")
    }

    func testSameURLSameBridgeAgentIdIsSameBridgeTrue() {
        let sharedURL = "wss://192.168.1.10:8767"
        addEntity(iosId: "ios-1", bridgeId: "bridge-aaa", url: sharedURL, cwd: "/code/project")

        let existingBridgeId = repository.findAgentByUrl(sharedURL)?.bridgeAgentId
        let newBridgeId = "bridge-aaa" // re-scan of the same bridge

        let isSameBridge: Bool
        if let newId = newBridgeId as String?,
           let existingId = existingBridgeId,
           !newId.isEmpty, !existingId.isEmpty {
            isSameBridge = (newId == existingId)
        } else {
            isSameBridge = true
        }

        XCTAssertTrue(isSameBridge,
            "Same bridgeAgentId on re-scan must trigger credential refresh, not new agent creation")
    }

    // MARK: - Helper

    private func addEntity(iosId: String, bridgeId: String, url: String, cwd: String) {
        repository.addAgent(agentId: iosId, name: "Agent \(iosId)", url: url, protocolVersion: "acp")
        if let entity = repository.getAgentEntity(agentId: iosId) {
            entity.bridgeAgentId = bridgeId
            entity.cwd = cwd
            repository.updateAgent(entity)
        }
    }
}

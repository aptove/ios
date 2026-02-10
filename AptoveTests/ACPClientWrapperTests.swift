import XCTest
@testable import Aptove

// MARK: - ConnectionState Tests

/// Tests for ACPClientWrapper connection state management.
///
/// These tests validate that `connectionState` transitions correctly
/// and that the reconnect-on-transport-failure logic works as specified
/// in the client-reconnect spec.
final class ACPClientWrapperTests: XCTestCase {

    // MARK: - Helpers

    private func makeConfig(url: String = "wss://localhost:3001") -> ConnectionConfig {
        ConnectionConfig(url: url, authToken: "test-token")
    }

    // MARK: - Initial State

    @MainActor
    func testInitialStateIsDisconnected() {
        let wrapper = ACPClientWrapper(config: makeConfig(), agentId: "test-agent")

        if case .disconnected = wrapper.connectionState {
            // expected
        } else {
            XCTFail("Expected initial connectionState to be .disconnected, got \(wrapper.connectionState)")
        }
    }

    @MainActor
    func testSessionIdIsNilBeforeConnect() {
        let wrapper = ACPClientWrapper(config: makeConfig(), agentId: "test-agent")
        XCTAssertNil(wrapper.sessionId, "sessionId should be nil before connecting")
    }

    // MARK: - Connection Failure

    @MainActor
    func testConnectWithUnresolvableHostSetsErrorState() async {
        // Use a properly-schemed URL that DNS will never resolve.
        // Note: bare invalid strings like "not a url" pass URL(string:) in modern
        // Foundation but crash CFNetwork with an uncatchable ObjC NSException,
        // so we must use a wss:// URL here.
        let wrapper = ACPClientWrapper(
            config: makeConfig(url: "wss://this.host.does.not.exist.invalid:9999"),
            agentId: "test-agent",
            connectionTimeout: 5,
            maxRetries: 1
        )

        await wrapper.connect()

        if case .error = wrapper.connectionState {
            // expected — unresolvable host should produce an error state
        } else {
            XCTFail("Expected connectionState to be .error after connecting with unresolvable host, got \(wrapper.connectionState)")
        }
    }

    @MainActor
    func testConnectToUnreachableHostSetsErrorState() async {
        let wrapper = ACPClientWrapper(
            config: makeConfig(url: "wss://127.0.0.1:19999"),
            agentId: "test-agent",
            connectionTimeout: 5,
            maxRetries: 1
        )

        await wrapper.connect()

        if case .error = wrapper.connectionState {
            // expected — unreachable host should result in error state
        } else {
            XCTFail("Expected connectionState to be .error after failing to connect, got \(wrapper.connectionState)")
        }
    }

    // MARK: - sendMessage Without Connection

    @MainActor
    func testSendMessageWithoutConnectionThrows() async {
        let wrapper = ACPClientWrapper(config: makeConfig(), agentId: "test-agent")

        do {
            try await wrapper.sendMessage(
                "hello",
                onChunk: { _ in },
                onComplete: { _ in }
            )
            XCTFail("sendMessage should throw when not connected")
        } catch {
            // Expected — should throw ClientError.noActiveSession
        }
    }

    // MARK: - Disconnect

    @MainActor
    func testDisconnectSetsStateToDisconnected() async {
        let wrapper = ACPClientWrapper(config: makeConfig(), agentId: "test-agent")

        await wrapper.disconnect()

        if case .disconnected = wrapper.connectionState {
            // expected
        } else {
            XCTFail("Expected connectionState to be .disconnected after disconnect(), got \(wrapper.connectionState)")
        }

        XCTAssertNil(wrapper.sessionId, "sessionId should be nil after disconnect")
    }

    // MARK: - Connection Config

    @MainActor
    func testConfigRetainsValues() {
        let config = ConnectionConfig(
            url: "wss://my-bridge.example.com/ws",
            clientId: "cf-id",
            clientSecret: "cf-secret",
            authToken: "secret-123"
        )
        let wrapper = ACPClientWrapper(config: config, agentId: "agent-42", connectionTimeout: 60, maxRetries: 5)

        XCTAssertEqual(wrapper.config.websocketURL, "wss://my-bridge.example.com/ws")
        XCTAssertEqual(wrapper.agentId, "agent-42")
        XCTAssertEqual(wrapper.connectionTimeout, 60)
        XCTAssertEqual(wrapper.maxRetries, 5)
    }
}

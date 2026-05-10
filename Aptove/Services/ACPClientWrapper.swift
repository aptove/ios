import Foundation
import ACP
import ACPHTTP
import ACPModel
import CommonCrypto

/// Client implementation that collects streaming responses
@MainActor
private class AptoveClient: @preconcurrency Client, ClientSessionOperations {
    
    init() {
        print("👤 AptoveClient: Initializing...")
    }
    var capabilities: ClientCapabilities {
        ClientCapabilities(terminal: true) // Enable terminal to see if agent calls us
    }
    
    var info: Implementation? {
        Implementation(name: "Aptove", version: "1.0.0")
    }
    
    // Callbacks to handle session updates
    var onUpdate: ((SessionUpdate) -> Void)?
    var onThought: ((String) -> Void)?
    var onToolCall: ((String) -> Void)?
    var onToolUpdate: ((String, String) -> Void)? // (toolCallId, content)

    // Back-reference to the wrapper for persistent callbacks
    weak var wrapper: ACPClientWrapper? {
        didSet {
            guard let w = wrapper, !pendingAvailableCommands.isEmpty else { return }
            w.cachedAvailableCommands = pendingAvailableCommands
            w.onAvailableCommandsUpdate?(pendingAvailableCommands)
        }
    }

    // Buffer for available_commands_update that arrives before wrapper is set
    var pendingAvailableCommands: [AvailableCommand] = []

    //Store pending permission requests with continuations
    var pendingPermissions: [String: CheckedContinuation<RequestPermissionResponse, Error>] = [:]
    var pendingPermissionOptions: [String: [PermissionOption]] = [:]
    var onPermissionRequest: ((String, ToolCallUpdateData, [PermissionOption]) -> Void)?
    
    // Terminal approval (not yet supported — terminalCreate auto-rejects)
    
    func onSessionUpdate(_ update: SessionUpdate) async {
        print("📨 Session update: \(update)")

        // Route availableCommandsUpdate through the persistent wrapper callback
        if case .availableCommandsUpdate(let u) = update {
            pendingAvailableCommands = u.availableCommands
            wrapper?.cachedAvailableCommands = u.availableCommands
            wrapper?.onAvailableCommandsUpdate?(u.availableCommands)
            return
        }

        // Log tool calls specially to debug approval flow
        if case .toolCall(let toolCallUpdate) = update {
            print("🔧 Tool call details:")
            print("   - ID: \(toolCallUpdate.toolCallId.value)")
            print("   - Title: \(toolCallUpdate.title)")
            print("   - Kind: \(String(describing: toolCallUpdate.kind))")
            print("   - Status: \(String(describing: toolCallUpdate.status))")
            print("   - RawInput: \(String(describing: toolCallUpdate.rawInput))")
        }

        onUpdate?(update)
    }
    
    func requestPermissions(
        toolCall: ToolCallUpdateData,
        permissions: [PermissionOption],
        meta: MetaField?
    ) async throws -> RequestPermissionResponse {
        print("🔐 requestPermissions CALLED for toolCallId: \(toolCall.toolCallId.value), title: \(toolCall.title ?? "nil")")
        print("🔐 Permissions count: \(permissions.count)")
        return try await withCheckedThrowingContinuation { continuation in
            let requestId = toolCall.toolCallId.value
            pendingPermissions[requestId] = continuation
            pendingPermissionOptions[requestId] = permissions
            print("🔐 Calling onPermissionRequest handler")
            onPermissionRequest?(requestId, toolCall, permissions)
        }
    }
    
    func notify(notification: SessionUpdate, meta: MetaField?) async {
        await onSessionUpdate(notification)
    }
    
    // Terminal Operations — not yet supported on iOS; auto-reject to avoid hanging the agent.
    func terminalCreate(request: CreateTerminalRequest) async throws -> CreateTerminalResponse {
        print("🖥️ terminalCreate CALLED - command: \(request.command) — auto-rejecting (unsupported)")
        throw ClientError.notImplemented("Terminal commands are not supported on iOS")
    }
    
    func terminalOutput(sessionId: SessionId, terminalId: String, meta: MetaField?) async throws -> TerminalOutputResponse {
        print("🖥️ terminalOutput CALLED for terminal: \(terminalId)")
        return TerminalOutputResponse(output: "", truncated: false, exitStatus: nil)
    }
    
    func terminalRelease(sessionId: SessionId, terminalId: String, meta: MetaField?) async throws {
        print("🖥️ terminalRelease CALLED for terminal: \(terminalId)")
    }
    
    // FileSystemOperations stubs - not implemented
    func fsReadTextFile(
        sessionId: SessionId,
        path: String,
        line: UInt32?,
        limit: UInt32?,
        meta: MetaField?
    ) async throws -> ReadTextFileResponse {
        throw ClientError.notImplemented("File system operations not supported")
    }
    
    func fsWriteTextFile(
        sessionId: SessionId,
        path: String,
        content: String,
        meta: MetaField?
    ) async throws -> WriteTextFileResponse {
        throw ClientError.notImplemented("File system operations not supported")
    }
}

enum ConnectionState {
    case disconnected
    case connecting
    case connected
    case error(String)
}

@MainActor
class ACPClientWrapper: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var connectionMessage: String = ""
    @Published var sessionWasResumed: Bool? = nil // nil = unknown, true = resumed, false = new
    
    /// Stable identifier for this device's connection, sent as X-Client-Id header.
    /// Used to suppress echoes of our own messages from bridge/remoteUserMessage.
    let deviceClientId: String = UUID().uuidString

    let config: ConnectionConfig
    let agentId: String
    let connectionTimeout: TimeInterval
    let maxRetries: Int

    /// Maximum number of transparent reconnect attempts when a transport error
    /// is detected during `sendMessage()`. Set to 0 to disable auto-reconnect.
    let maxReconnectAttempts: Int

    /// The working directory to send when creating sessions (from bridge pairing).
    let cwd: String
    
    /// The agent's self-reported name (from InitializeResponse)
    private(set) var connectedAgentName: String?
    
    /// Whether the agent supports loading sessions
    private(set) var supportsLoadSession: Bool = false
    
    /// Get the current session ID (if connected)
    var sessionId: String? {
        currentSessionId?.value
    }

    private var connection: ClientConnection?
    private var transport: (any Transport)?
    private var currentSessionId: SessionId?
    private var client: AptoveClient?
    
    // Store for collecting agent responses
    private var currentResponse: String = ""
    
    nonisolated init(config: ConnectionConfig, agentId: String, connectionTimeout: TimeInterval = 300, maxRetries: Int = 3, maxReconnectAttempts: Int = 1) {
        print("🔌 ACPClientWrapper: Initializing for agent \(agentId)")
        print("🔌 ACPClientWrapper: URL: \(config.websocketURL)")
        print("🔌 ACPClientWrapper: Timeout: \(connectionTimeout)s, Max retries: \(maxRetries), Max reconnect: \(maxReconnectAttempts)")
        self.config = config
        self.agentId = agentId
        self.connectionTimeout = connectionTimeout
        self.maxRetries = maxRetries
        self.maxReconnectAttempts = maxReconnectAttempts
        self.cwd = config.cwd
        print("🔌 ACPClientWrapper: Initialization complete (cwd: \(self.cwd))")
    }
    
    func connect() async {
        await connect(existingSessionId: nil)
    }
    
    func connect(existingSessionId: String?) async {
        print("🔌 ACPClientWrapper.connect(): Starting connection flow...")
        if let sessionId = existingSessionId {
            print("🔌 ACPClientWrapper.connect(): Will try to load session: \(sessionId)")
        }
        connectionState = .connecting
        connectionMessage = "Connecting to agent..."
        
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            print("🔌 ACPClientWrapper.connect(): Attempt \(attempt)/\(maxRetries)")
            var attemptTransport: WebSocketTransport? = nil
            do {
                if attempt > 1 {
                    connectionMessage = "Retrying connection (\(attempt)/\(maxRetries))..."
                    print("🔌 ACPClientWrapper.connect(): Waiting 2s before retry...")
                    // Wait a bit before retrying
                    try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                }
                
                print("🔌 ACPClientWrapper.connect(): Validating URL...")
                guard let url = URL(string: config.websocketURL) else {
                    print("❌ ACPClientWrapper.connect(): Invalid URL: \(config.websocketURL)")
                    connectionState = .error("Invalid URL")
                    return
                }
                print("🔌 ACPClientWrapper.connect(): URL valid: \(url)")
                
                // Create URLSession with optional CF-Access headers
                print("🔌 ACPClientWrapper.connect(): Configuring URLSession...")
                let configuration = URLSessionConfiguration.default
                // Don't set timeouts for WebSocket connections - they need to stay open indefinitely
                // Only use connectionTimeout for the initial connection attempt
                configuration.timeoutIntervalForRequest = TimeInterval.infinity
                configuration.timeoutIntervalForResource = TimeInterval.infinity
                
                var headers: [String: String] = [:]
                
                // Only add CF-Access headers if credentials are provided
                if let clientId = config.clientId, !clientId.isEmpty {
                    print("🔌 ACPClientWrapper.connect(): Adding CF-Access-Client-Id header")
                    headers["CF-Access-Client-Id"] = clientId
                }
                
                if let clientSecret = config.clientSecret, !clientSecret.isEmpty {
                    print("🔌 ACPClientWrapper.connect(): Adding CF-Access-Client-Secret header")
                    headers["CF-Access-Client-Secret"] = clientSecret
                }
                
                // Add bridge auth token if provided
                if let authToken = config.authToken, !authToken.isEmpty {
                    print("🔌 ACPClientWrapper.connect(): Adding X-Bridge-Token header")
                    headers["X-Bridge-Token"] = authToken
                }

                // Add client ID for multi-device message sync
                headers["X-Client-Id"] = deviceClientId
                
                if !headers.isEmpty {
                    print("🔌 ACPClientWrapper.connect(): Setting \(headers.count) HTTP headers")
                    configuration.httpAdditionalHeaders = headers
                } else {
                    print("🔌 ACPClientWrapper.connect(): No additional headers needed")
                }
                
                // Create URLSession with optional certificate pinning delegate
                let session: URLSession
                if config.hasSelfSignedCert {
                    print("🔌 ACPClientWrapper.connect(): Creating URLSession with self-signed cert support...")
                    print("🔐 Expected fingerprint: \(config.certFingerprint ?? "none")")
                    let delegate = SelfSignedCertificateDelegate(expectedFingerprint: config.certFingerprint)
                    session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
                } else {
                    print("🔌 ACPClientWrapper.connect(): Creating standard URLSession...")
                    session = URLSession(configuration: configuration)
                }
                
                connectionMessage = "Establishing connection...\nThis may take a moment if authorization is required."
                
                print("🔌 ACPClientWrapper.connect(): Creating WebSocketTransport...")
                let wsTransport = WebSocketTransport(url: url, session: session)
                attemptTransport = wsTransport
                let filteredTransport = BridgeFilteringTransport(inner: wsTransport) { [weak self] notif in
                    self?.handleBridgeNotification(notif)
                }
                self.transport = wsTransport

                print("🔌 ACPClientWrapper.connect(): Creating AptoveClient...")
                // Cancel any continuations from the previous client before replacing it.
                cancelPendingClientRequests()
                let client = AptoveClient()
                client.wrapper = self
                self.client = client
                print("🔌 ACPClientWrapper.connect(): Client created")

                // Set up permission request handler
                print("🔌 ACPClientWrapper.connect(): Setting up permission request handler...")
                client.onPermissionRequest = { [weak self] requestId, toolCall, permissions in
                    print("🔐 Permission request received in handler: \(requestId)")
                    Task { @MainActor in
                        guard let self = self else { return }

                        // Extract command from toolCall
                        var command: String?
                        if case .object(let dict) = toolCall.rawInput,
                           case .string(let cmd) = dict["command"] {
                            command = cmd
                        }

                        let title = toolCall.title ?? "Tool Approval Required"
                        print("⚠️ Permission request: \(title), options: \(permissions.count)")
                        self.onToolApprovalRequest?(requestId, title, command, permissions)
                    }
                }

                // Pass the connectionTimeout to ensure Protocol layer respects our extended timeout
                print("🔌 ACPClientWrapper.connect(): Creating ClientConnection...")
                let conn = ClientConnection(transport: filteredTransport, client: client, defaultTimeoutSeconds: connectionTimeout)
                print("🔌 ACPClientWrapper.connect(): ClientConnection created")
                
                // Connect and initialize with a short deadline so a silent bridge
                // (connected but not responding) fails fast and triggers a retry.
                // Always close the transport on failure so the bridge releases the connection slot.
                let initializeTimeout: TimeInterval = 30
                connectionMessage = "Initializing agent..."
                print("🔌 ACPClientWrapper.connect(): Calling conn.connect() (timeout: \(Int(initializeTimeout))s)...")
                let agentInfo = try await withThrowingTaskGroup(of: Implementation?.self) { group in
                    group.addTask { try await conn.connect() }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(initializeTimeout * 1_000_000_000))
                        throw URLError(.timedOut)
                    }
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }
                print("✅ ACPClientWrapper.connect(): Connection established!")
                
                // Store the agent's self-reported name from the InitializeResponse
                self.connectedAgentName = agentInfo?.name
                if let name = self.connectedAgentName {
                    print("🤖 ACPClientWrapper.connect(): Agent name: \(name)")
                }
                
                // Store loadSession capability
                let capabilities = await conn.agentCapabilities
                self.supportsLoadSession = capabilities?.loadSession ?? false
                print("🔄 ACPClientWrapper.connect(): Agent supports loadSession: \(self.supportsLoadSession)")
                
                // Try to load existing session if provided and supported
                var sessionLoaded = false
                if let sessionIdToLoad = existingSessionId, self.supportsLoadSession {
                    connectionMessage = "Resuming session..."
                    print("🔄 ACPClientWrapper.connect(): Attempting to load session: \(sessionIdToLoad)")
                    
                    do {
                        let loadRequest = LoadSessionRequest(
                            sessionId: SessionId(value: sessionIdToLoad),
                            cwd: self.cwd,
                            mcpServers: []
                        )
                        _ = try await conn.loadSession(request: loadRequest)
                        self.currentSessionId = SessionId(value: sessionIdToLoad)
                        sessionLoaded = true
                        self.sessionWasResumed = true
                        print("✅ ACPClientWrapper.connect(): Session loaded successfully: \(sessionIdToLoad)")
                    } catch {
                        print("⚠️ ACPClientWrapper.connect(): Failed to load session: \(error.localizedDescription)")
                        // Will fall through to create new session
                    }
                }
                
                // Create new session if we didn't load one
                if !sessionLoaded {
                    connectionMessage = "Creating session..."
                    print("🔧 Creating session with cwd: \(self.cwd)")

                    let sessionRequest = NewSessionRequest(cwd: self.cwd, mcpServers: [])
                    print("🔌 ACPClientWrapper.connect(): Calling conn.createSession()...")
                    let sessionResponse = try await conn.createSession(request: sessionRequest)
                    print("✅ Session created with ID: \(sessionResponse.sessionId)")
                    self.currentSessionId = sessionResponse.sessionId
                    self.sessionWasResumed = false
                }
                
                    self.connection = conn
                    connectionMessage = "Connected successfully!"
                    connectionState = .connected
                    print("✅ ACPClientWrapper.connect(): Connection flow complete!")

                    // Watch for unexpected transport close (network loss, bridge restart, etc.)
                    // Cancelled in disconnect() so intentional closes don't fire this callback.
                    guard let capturedTransport = transport else { break }
                    transportObserverTask?.cancel()
                    transportObserverTask = Task { [weak self] in
                        for await state in capturedTransport.state {
                            guard let self else { return }
                            if state == .closed {
                                if case .connected = self.connectionState {
                                    print("🔌 ACPClientWrapper: Transport closed unexpectedly — signalling disconnect")
                                    self.connectionState = .disconnected
                                    self.onUnexpectedDisconnect?()
                                }
                                return
                            }
                        }
                    }

                    // Register push token with bridge after successful connection
                    Task {
                        await self.registerPushToken()
                    }

                    return
            } catch {
                    // Close the transport explicitly so the bridge releases the connection slot.
                    // Without this, timed-out or failed WebSocketTasks linger on the server,
                    // eventually exhausting the bridge's concurrent connection limit.
                    print("🔌 ACPClientWrapper.connect(): Closing transport after failed attempt \(attempt)")
                    await attemptTransport?.close()
                    self.transport = nil

                    lastError = error
                    print("❌ Connection attempt \(attempt) failed: \(error)")
                    print("❌ Error type: \(type(of: error))")
                    print("❌ Error localized: \(error.localizedDescription)")
            }
        }
        
        // All retries failed
        print("❌ ACPClientWrapper.connect(): All \(maxRetries) attempts failed")
        let errorMessage = lastError?.localizedDescription ?? "Connection failed"
        connectionMessage = ""
        connectionState = .error("Failed after \(maxRetries) attempts: \(errorMessage)")
    }
    
    func disconnect() async {
        // Cancel the transport observer first so an intentional disconnect
        // does not trigger the unexpected-disconnect callback.
        transportObserverTask?.cancel()
        transportObserverTask = nil

        // Resume any suspended permission continuations so the agent isn't left hanging.
        cancelPendingClientRequests()

        if let conn = connection {
            await conn.disconnect()
            connection = nil
            currentSessionId = nil
        }

        connectionState = .disconnected
    }

    /// Clear the conversation history while keeping the session ID and workspace.
    /// This reconnects with the same session ID, which causes the agent to clear session.md
    func clearSession() async {
        print("🗑️ Clearing session conversation history...")

        // Disconnect current connection
        await disconnect()

        // Reconnect - this will reuse the stored session ID and clear the conversation
        await connect()

        print("✅ Session conversation cleared, workspace retained")
    }
    
    /// Register the APNs push token with the bridge for background notifications
    func registerPushToken() async {
        let pushManager = PushNotificationManager.shared
        
        guard let deviceToken = await pushManager.getDeviceToken() else {
            print("📲 ACPClientWrapper: No push token available, skipping registration")
            return
        }
        
        guard let transport = self.transport else {
            print("📲 ACPClientWrapper: No transport, cannot register push token")
            return
        }
        
        let bundleId = pushManager.bundleId
        
        // Build JSON-RPC notification using the SDK's public types
        let params: JsonValue = .object([
            "platform": .string("apns"),
            "deviceToken": .string(deviceToken),
            "bundleId": .string(bundleId)
        ])
        
        let notification = JsonRpcNotification(method: "bridge/registerPushToken", params: params)
        let message = JsonRpcMessage.notification(notification)
        
        do {
            print("📲 ACPClientWrapper: Registering push token with bridge (platform=apns, bundleId=\(bundleId))")
            try await transport.send(message)
            print("✅ ACPClientWrapper: Push token registered with bridge")
        } catch {
            print("❌ ACPClientWrapper: Failed to register push token: \(error)")
        }
    }
    
    /// Unregister the push token from the bridge
    func unregisterPushToken() async {
        let pushManager = PushNotificationManager.shared
        
        guard let deviceToken = pushManager.deviceToken else { return }
        guard let transport = self.transport else { return }
        
        let params: JsonValue = .object([
            "deviceToken": .string(deviceToken)
        ])
        
        let notification = JsonRpcNotification(method: "bridge/unregisterPushToken", params: params)
        let message = JsonRpcMessage.notification(notification)
        
        do {
            print("📲 ACPClientWrapper: Unregistering push token from bridge")
            try await transport.send(message)
        } catch {
            print("❌ ACPClientWrapper: Failed to unregister push token: \(error)")
        }
    }
    
    /// Correct a voice transcript using the AI agent.
    /// Returns the corrected text, or the raw transcript if correction fails.
    func correctTranscript(_ rawTranscript: String, language: String) async -> String {
        let instructions = language.hasPrefix("tr")
            ? "Transkripsiyon hatalarını, noktalama işaretlerini ve dil bilgisini düzelt. Yalnızca tek bir alanlı geçerli JSON döndür: {\"corrected_text\": \"...\"}"
            : "Fix transcription errors, punctuation, and grammar. Return ONLY valid JSON with a single field: {\"corrected_text\": \"...\"}"

        func encodeJson(_ s: String) -> String {
            "\"" + s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
            + "\""
        }

        let json = """
        {"type":"voice_correction_request","version":"1.0","language":\(encodeJson(language)),"instructions":\(encodeJson(instructions)),"raw_transcript":\(encodeJson(rawTranscript))}
        """

        var accumulated = ""
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                do {
                    try await self.sendMessage(json, onChunk: { accumulated += $0 }, onComplete: { _, _ in cont.resume() })
                } catch {
                    cont.resume()
                }
            }
        }

        // Parse {"corrected_text": "..."}
        if let data = accumulated.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let corrected = obj["corrected_text"] as? String,
           !corrected.isEmpty {
            return corrected
        }
        return rawTranscript
    }

    /// Append a memory entry to the bridge's MEMORY.md file.
    func sendMemoryEntry(_ text: String) async {
        guard let transport = self.transport else {
            print("❌ ACPClientWrapper: No transport, cannot send memory entry")
            return
        }
        let params: JsonValue = .object(["text": .string(text)])
        let notification = JsonRpcNotification(method: "bridge/appendMemory", params: params)
        let message = JsonRpcMessage.notification(notification)
        do {
            try await transport.send(message)
            print("🧠 ACPClientWrapper: Memory entry sent")
        } catch {
            print("❌ ACPClientWrapper: Failed to send memory entry: \(error)")
        }
    }

    /// Called when the WebSocket transport closes unexpectedly (not via `disconnect()`).
    /// Use this to trigger multi-transport reconnect logic in AgentManager.
    var onUnexpectedDisconnect: (() -> Void)?
    private var transportObserverTask: Task<Void, Never>?

    /// Called when another device sends a user message to the same session.
    /// The string is the plain text of the remote message.
    var onRemoteUserMessage: ((String) -> Void)?

    /// Cache of the last received available commands — populated before the callback fires
    /// so late subscribers (e.g. ChatViewModel) can read them on first subscription.
    fileprivate(set) var cachedAvailableCommands: [AvailableCommand] = []

    /// Persistent callback for available commands updates (fired outside of sendMessage scope).
    /// Setting this property immediately replays the cached commands if any are already known.
    var onAvailableCommandsUpdate: (([AvailableCommand]) -> Void)? {
        didSet { if let f = onAvailableCommandsUpdate, !cachedAvailableCommands.isEmpty { f(cachedAvailableCommands) } }
    }

    // Streaming callback for real-time updates
    var onResponseChunk: ((String) -> Void)?
    var onThought: ((String) -> Void)?
    var onToolCall: ((String) -> Void)?
    var onToolUpdate: ((String, String) -> Void)? // (toolCallId, content)
    var onComplete: ((StopReason) -> Void)?
    var onToolApprovalRequest: ((String, String, String?, [PermissionOption]) -> Void)? // toolCallId, title, command, options
    
    // Store pending tool approval requests
    private var pendingToolRequests: [String: ToolCallUpdateData] = [:] // toolCallId -> ToolCallUpdateData
    
    func sendMessage(_ text: String, onChunk: @escaping (String) -> Void, onThought: ((String) -> Void)? = nil, onToolCall: ((String) -> Void)? = nil, onToolUpdate: ((String, String) -> Void)? = nil, onComplete: @escaping (StopReason?, String?) -> Void = { _, _ in }) async throws {
        try await sendMessage([.text(TextContent(text: text))], onChunk: onChunk, onThought: onThought, onToolCall: onToolCall, onToolUpdate: onToolUpdate, onComplete: onComplete)
    }

    func sendMessage(_ content: [ContentBlock], onChunk: @escaping (String) -> Void, onThought: ((String) -> Void)? = nil, onToolCall: ((String) -> Void)? = nil, onToolUpdate: ((String, String) -> Void)? = nil, onComplete: @escaping (StopReason?, String?) -> Void = { _, _ in }) async throws {
        guard let conn = connection, let sessionId = currentSessionId, let client = client else {
            throw ClientError.noActiveSession
        }

        print("📤 Sending prompt to session: \(sessionId.value)")
        print("📤 Content blocks: \(content.count)")
        
        // Capture callbacks locally so each call's closure is fully isolated.
        // Do NOT write to instance properties here — concurrent calls would overwrite them
        // and cause voice-correction responses to leak into the wrong handler.
        let capturedOnThought    = onThought
        let capturedOnToolCall   = onToolCall
        let capturedOnToolUpdate = onToolUpdate

        // Set up streaming response collector
        client.onUpdate = { [weak self] update in
            guard self != nil else { return }

            switch update {
            case .agentMessageChunk(let chunk):
                if case .text(let textContent) = chunk.content {
                    print("📥 Agent response chunk: \(textContent.text)")
                    onChunk(textContent.text)
                }
            case .agentThoughtChunk(let chunk):
                if case .text(let textContent) = chunk.content {
                    print("💭 Agent thought: \(textContent.text)")
                    capturedOnThought?(textContent.text)
                }
            case .toolCall(let toolCall):
                print("🔧 Tool call: \(toolCall.title) - status: \(String(describing: toolCall.status))")
                capturedOnToolCall?(toolCall.title)
            case .toolCallUpdate(let toolUpdate):
                print("🔧 Tool update: \(toolUpdate.toolCallId.value) - status: \(String(describing: toolUpdate.status))")
                // Extract text content from the update
                var textContent = ""
                if let content = toolUpdate.content {
                    for item in content {
                        if case .content(let contentData) = item,
                           case .text(let textData) = contentData.content {
                            textContent += textData.text
                        }
                    }
                }
                // Only surface updates that carry actual text content
                if !textContent.isEmpty {
                    print("📥 Tool output: \(textContent)")
                    capturedOnToolUpdate?(toolUpdate.toolCallId.value, textContent)
                } else if let status = toolUpdate.status {
                    print("📥 Tool status change (suppressed from UI): \(status)")
                }
            default:
                print("📨 Other update: \(update)")
            }
        }
        
        let promptRequest = PromptRequest(
            sessionId: sessionId,
            prompt: content
        )
        
        print("📤 Prompt request created: \(promptRequest)")
        
        // Send prompt in background - don't block main thread
        // Captures `sessionId` (the value at call time) for reconnect-retry.
        let savedSessionId = sessionId.value
        let reconnectLimit = self.maxReconnectAttempts
        
        Task {
            do {
                let response = try await conn.prompt(request: promptRequest)
                print("📥 Prompt completed: \(response.stopReason)")
                
                // Small delay to ensure final chunks arrive
                try? await Task.sleep(nanoseconds: 100_000_000)
                
                await MainActor.run {
                    onComplete(response.stopReason, nil)
                }
            } catch {
                print("❌ Prompt error: \(error)")
                
                // --- Distinguish agent errors from transport errors ---
                // JSON-RPC errors from the agent (quota exceeded, invalid
                // request, etc.) should NOT trigger reconnect — surface
                // the error message directly to the user.
                if let agentErrorMessage = Self.agentErrorMessage(from: error) {
                    print("⚠️ Agent error (no reconnect): \(agentErrorMessage)")
                    await MainActor.run {
                        onComplete(nil, agentErrorMessage)
                    }
                    return
                }

                // --- Auto-reconnect on transport failure ---
                // If the WebSocket died silently, conn.prompt() throws a
                // transport error. We mark disconnected, reconnect using
                // the existing session ID (bridge keeps it alive), and
                // retry the prompt once.
                guard reconnectLimit > 0 else {
                    print("🔄 Auto-reconnect disabled (maxReconnectAttempts=0)")
                    await MainActor.run {
                        self.connectionState = .disconnected
                        onComplete(nil, error.localizedDescription)
                    }
                    return
                }

                // If the agent says the session doesn't exist, clear it
                // so the reconnect creates a fresh session instead of
                // retrying the same stale session ID in a loop.
                let isSessionNotFound = Self.isSessionNotFoundError(error)
                let reconnectSessionId: String? = isSessionNotFound ? nil : savedSessionId
                if isSessionNotFound {
                    print("🔄 Session not found — will create new session on reconnect")
                    await MainActor.run { self.currentSessionId = nil }
                }

                for attempt in 1...reconnectLimit {
                    print("🔄 Transport error detected — reconnect attempt \(attempt)/\(reconnectLimit)")

                    await MainActor.run {
                        self.connectionState = .disconnected
                        self.connection = nil
                        self.transport = nil
                    }

                    // Reconnect using the saved session ID so the bridge
                    // resumes the existing agent session. If the session was
                    // not found, connect without a session ID to create a new one.
                    await self.connect(existingSessionId: reconnectSessionId)
                    
                    let reconnected: Bool = await MainActor.run {
                        if case .connected = self.connectionState { return true }
                        return false
                    }
                    
                    guard reconnected else {
                        print("❌ Reconnect attempt \(attempt) failed — connection not restored")
                        continue
                    }
                    
                    print("✅ Reconnected — retrying prompt")
                    
                    // Rebuild the prompt request with the (possibly new) session ID
                    guard let newConn = await MainActor.run(body: { self.connection }),
                          let newSessionId = await MainActor.run(body: { self.currentSessionId }) else {
                        print("❌ Connection objects nil after reconnect")
                        continue
                    }
                    
                    let retryRequest = PromptRequest(
                        sessionId: newSessionId,
                        prompt: content
                    )
                    
                    do {
                        let retryResponse = try await newConn.prompt(request: retryRequest)
                        print("📥 Retry prompt completed: \(retryResponse.stopReason)")

                        try? await Task.sleep(nanoseconds: 100_000_000)

                        await MainActor.run {
                            onComplete(retryResponse.stopReason, nil)
                        }
                        return // success — exit the retry loop
                    } catch {
                        print("❌ Retry prompt also failed: \(error)")
                        // Loop continues to next reconnect attempt (if any)
                    }
                }
                
                // All reconnect attempts exhausted
                print("❌ All \(reconnectLimit) reconnect attempt(s) failed")
                await MainActor.run {
                    onComplete(nil, "Connection lost — could not reconnect")
                }
            }
        }
    }
    
    func approveTool(toolCallId: String, optionId: String = "allow_once") async throws {
        guard let client = client,
              let continuation = client.pendingPermissions[toolCallId] else {
            throw ClientError.invalidToolCall
        }
        
        print("✅ Tool approved: \(toolCallId) with option: \(optionId)")
        
        // Resume the continuation with the selected option
        let response = RequestPermissionResponse(
            outcome: .selected(PermissionOptionId(value: optionId))
        )
        
        continuation.resume(returning: response)
        client.pendingPermissions.removeValue(forKey: toolCallId)
        client.pendingPermissionOptions.removeValue(forKey: toolCallId)
    }
    
    func rejectTool(toolCallId: String) async throws {
        guard let client = client,
              let continuation = client.pendingPermissions[toolCallId] else {
            throw ClientError.invalidToolCall
        }
        
        print("❌ Tool rejected: \(toolCallId)")
        
        // Resume the continuation with reject_once option
        let response = RequestPermissionResponse(
            outcome: .selected(PermissionOptionId(value: "reject_once"))
        )
        
        continuation.resume(returning: response)
        client.pendingPermissions.removeValue(forKey: toolCallId)
        client.pendingPermissionOptions.removeValue(forKey: toolCallId)
    }
    
    func getPermissionOptions(for toolCallId: String) -> [PermissionOption]? {
        return client?.pendingPermissionOptions[toolCallId]
    }

    /// Resume all suspended permission continuations with an error so the agent side
    /// is not left hanging when the connection drops or a new client is created.
    private func cancelPendingClientRequests() {
        guard let client = client else { return }
        for continuation in client.pendingPermissions.values {
            continuation.resume(throwing: ClientError.invalidToolCall)
        }
        client.pendingPermissions.removeAll()
        client.pendingPermissionOptions.removeAll()
    }
    
    /// Check if an error is a "Session not found" JSON-RPC error from the agent.
    private static func isSessionNotFoundError(_ error: Error) -> Bool {
        let desc = String(describing: error)
        return desc.contains("Session not found")
    }

    /// Extract human-readable message from a JSON-RPC agent error.
    /// Returns `nil` for transport errors (which should trigger reconnect).
    private static func agentErrorMessage(from error: Error) -> String? {
        if let protoError = error as? ProtocolError {
            switch protoError {
            case .jsonRpcError(_, let message, _):
                // "Session not found" errors are handled separately via reconnect
                if message.contains("Session not found") { return nil }
                return message
            default:
                return nil // transport-level errors
            }
        }
        return nil
    }

    private func handleBridgeNotification(_ notif: JsonRpcNotification) {
        guard notif.method == "bridge/remoteUserMessage",
              case .object(let paramsObj) = notif.params,
              case .string(let senderId) = paramsObj["senderId"],
              senderId != deviceClientId else { return }

        guard case .array(let contentArray) = paramsObj["content"] else { return }

        let text = contentArray.compactMap { block -> String? in
            guard case .object(let blockObj) = block,
                  case .string(let t) = blockObj["text"] else { return nil }
            return t
        }.joined()

        guard !text.isEmpty else { return }
        onRemoteUserMessage?(text)
    }

    enum ClientError: LocalizedError {
        case noActiveSession
        case invalidResponse
        case invalidToolCall

        var errorDescription: String? {
            switch self {
            case .noActiveSession:
                return "No active session"
            case .invalidResponse:
                return "Invalid response from agent"
            case .invalidToolCall:
                return "Invalid or expired tool call"
            }
        }
    }
}

/// Wraps a Transport and intercepts `bridge/*` notifications before they reach the ACP SDK.
/// The ACP SDK has no handler for bridge-specific methods and would silently drop them.
final class BridgeFilteringTransport: Transport, @unchecked Sendable {
    private let inner: any Transport
    private let onBridgeNotification: (JsonRpcNotification) -> Void

    let messages: AsyncStream<JsonRpcMessage>
    private let messageContinuation: AsyncStream<JsonRpcMessage>.Continuation
    var state: AsyncStream<TransportState> { inner.state }

    init(inner: any Transport, onBridgeNotification: @escaping (JsonRpcNotification) -> Void) {
        self.inner = inner
        self.onBridgeNotification = onBridgeNotification
        var cont: AsyncStream<JsonRpcMessage>.Continuation!
        self.messages = AsyncStream { cont = $0 }
        self.messageContinuation = cont
    }

    func start() async throws {
        try await inner.start()
        let innerMessages = inner.messages
        let continuation = messageContinuation
        let handler = onBridgeNotification
        Task {
            for await message in innerMessages {
                if case .notification(let notif) = message, notif.method.hasPrefix("bridge/") {
                    handler(notif)
                } else {
                    continuation.yield(message)
                }
            }
            continuation.finish()
        }
    }

    func send(_ message: JsonRpcMessage) async throws { try await inner.send(message) }
    func close() async { messageContinuation.finish(); await inner.close() }
}

/// URLSession delegate to handle self-signed certificates
/// When a certificate fingerprint is provided, we validate the certificate matches
class SelfSignedCertificateDelegate: NSObject, URLSessionDelegate {
    let expectedFingerprint: String?
    
    init(expectedFingerprint: String?) {
        self.expectedFingerprint = expectedFingerprint
        super.init()
    }
    
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Only handle server trust challenges
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        // If no fingerprint provided, reject self-signed certs
        guard let expectedFingerprint = expectedFingerprint else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        // Get the server certificate
        if #available(iOS 15.0, *) {
            guard let certificates = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
                  let serverCert = certificates.first else {
                print("🔐 Failed to get server certificate")
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            
            // Calculate SHA256 fingerprint of the certificate
            let certData = SecCertificateCopyData(serverCert) as Data
            let fingerprint = sha256Fingerprint(of: certData)
            
            print("🔐 Server cert fingerprint: \(fingerprint)")
            print("🔐 Expected fingerprint: \(expectedFingerprint)")
            
            // Compare fingerprints (case-insensitive)
            if fingerprint.lowercased() == expectedFingerprint.lowercased() {
                print("🔐 Certificate fingerprint matches! Accepting connection.")
                let credential = URLCredential(trust: serverTrust)
                completionHandler(.useCredential, credential)
            } else {
                print("🔐 Certificate fingerprint MISMATCH! Rejecting connection.")
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        } else {
            // iOS 14 fallback - just trust if we have a fingerprint (less secure)
            print("🔐 iOS 14: Trusting connection with fingerprint")
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
        }
    }
    
    /// Calculate SHA256 fingerprint of certificate data, formatted as colon-separated hex
    private func sha256Fingerprint(of data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

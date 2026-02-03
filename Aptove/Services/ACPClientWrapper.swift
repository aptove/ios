import Foundation
import ACP
import ACPHTTP
import ACPModel
import CommonCrypto

/// Client implementation that collects streaming responses
@MainActor
private class AptoveClient: Client, ClientSessionOperations {
    
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
    
    //Store pending permission requests with continuations
    var pendingPermissions: [String: CheckedContinuation<RequestPermissionResponse, Error>] = [:]
    var pendingPermissionOptions: [String: [PermissionOption]] = [:]
    var onPermissionRequest: ((String, ToolCallUpdateData, [PermissionOption]) -> Void)?
    
    // Terminal approval
    var onTerminalApprovalRequest: ((String, String) -> Void)? // command, title
    var pendingTerminalApprovals: [String: CheckedContinuation<Bool, Never>] = [:] // command -> approved
    
    func onSessionUpdate(_ update: SessionUpdate) async {
        print("📨 Session update: \(update)")
        
        // Log tool calls specially to debug approval flow
        if case .toolCall(let toolCallUpdate) = update {
            print("🔧 Tool call details:")
            print("   - ID: \(toolCallUpdate.toolCallId.value)")
            print("   - Title: \(toolCallUpdate.title ?? "nil")")
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
    
    // Terminal Operations - with approval
    func terminalCreate(request: CreateTerminalRequest) async throws -> CreateTerminalResponse {
        print("🖥️ terminalCreate CALLED - command: \(request.command ?? "nil")")
        
        let command = request.command ?? "unknown command"
        
        // Request approval
        let approved = await withCheckedContinuation { continuation in
            let requestId = UUID().uuidString
            pendingTerminalApprovals[requestId] = continuation
            onTerminalApprovalRequest?(command, "Execute terminal command")
        }
        
        if !approved {
            throw ClientError.requestFailed("User rejected command execution")
        }
        
        // For now, return a fake terminal ID - actual execution would happen here
        print("✅ Terminal command approved, returning fake response")
        return CreateTerminalResponse(terminalId: UUID().uuidString)
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
    
    let config: ConnectionConfig
    let agentId: String
    let connectionTimeout: TimeInterval
    let maxRetries: Int
    
    /// The agent's self-reported name (from InitializeResponse)
    private(set) var connectedAgentName: String?
    
    /// Whether the agent supports loading sessions
    private(set) var supportsLoadSession: Bool = false
    
    /// Get the current session ID (if connected)
    var sessionId: String? {
        currentSessionId?.value
    }
    
    private var connection: ClientConnection?
    private var currentSessionId: SessionId?
    private var client: AptoveClient?
    
    // Store for collecting agent responses
    private var currentResponse: String = ""
    
    nonisolated init(config: ConnectionConfig, agentId: String, connectionTimeout: TimeInterval = 300, maxRetries: Int = 3) {
        print("🔌 ACPClientWrapper: Initializing for agent \(agentId)")
        print("🔌 ACPClientWrapper: URL: \(config.websocketURL)")
        print("🔌 ACPClientWrapper: Timeout: \(connectionTimeout)s, Max retries: \(maxRetries)")
        self.config = config
        self.agentId = agentId
        self.connectionTimeout = connectionTimeout
        self.maxRetries = maxRetries
        print("🔌 ACPClientWrapper: Initialization complete")
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
                let transport = WebSocketTransport(url: url, session: session)
                
                print("🔌 ACPClientWrapper.connect(): Creating AptoveClient...")
                let client = AptoveClient()
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
                let conn = ClientConnection(transport: transport, client: client, defaultTimeoutSeconds: connectionTimeout)
                print("🔌 ACPClientWrapper.connect(): ClientConnection created")
                
                // Connect and initialize with extended timeout
                connectionMessage = "Initializing agent...\nPlease wait, this can take up to \(Int(connectionTimeout)) seconds."
                print("🔌 ACPClientWrapper.connect(): Calling conn.connect()...")
                let agentInfo = try await conn.connect()
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
                            cwd: FileManager.default.currentDirectoryPath,
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
                    print("🔧 Creating session with cwd: \(FileManager.default.currentDirectoryPath)")
                    let sessionRequest = NewSessionRequest(
                        cwd: FileManager.default.currentDirectoryPath,
                        mcpServers: []
                    )
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
                return
                
            } catch {
                lastError = error
                print("❌ Connection attempt \(attempt) failed: \(error)")
                print("❌ Error type: \(type(of: error))")
                print("❌ Error localized: \(error.localizedDescription)")
                
                // Continue to retry on errors unless it's the last attempt
                // Some errors like network timeouts may succeed on retry
            }
        }
        
        // All retries failed
        print("❌ ACPClientWrapper.connect(): All \(maxRetries) attempts failed")
        let errorMessage = lastError?.localizedDescription ?? "Connection failed"
        connectionMessage = ""
        connectionState = .error("Failed after \(maxRetries) attempts: \(errorMessage)")
    }
    
    func disconnect() async {
        if let conn = connection {
            try? await conn.disconnect()
            connection = nil
            currentSessionId = nil
        }
        
        connectionState = .disconnected
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
    
    func sendMessage(_ text: String, onChunk: @escaping (String) -> Void, onThought: ((String) -> Void)? = nil, onToolCall: ((String) -> Void)? = nil, onToolUpdate: ((String, String) -> Void)? = nil, onComplete: @escaping (StopReason?) -> Void = { _ in }) async throws {
        guard let conn = connection, let sessionId = currentSessionId, let client = client else {
            throw ClientError.noActiveSession
        }
        
        print("📤 Sending prompt to session: \(sessionId.value)")
        print("📤 Message: \(text)")
        
        // Store callbacks
        self.onThought = onThought
        self.onToolCall = onToolCall
        self.onToolUpdate = onToolUpdate
        
        // Set up streaming response collector
        client.onUpdate = { [weak self] update in
            guard let self = self else { return }
            
            switch update {
            case .agentMessageChunk(let chunk):
                if case .text(let textContent) = chunk.content {
                    print("📥 Agent response chunk: \(textContent.text)")
                    onChunk(textContent.text)
                }
            case .agentThoughtChunk(let chunk):
                if case .text(let textContent) = chunk.content {
                    print("💭 Agent thought: \(textContent.text)")
                    self.onThought?(textContent.text)
                }
            case .toolCall(let toolCall):
                print("🔧 Tool call: \(toolCall.title ?? "Unknown") - status: \(String(describing: toolCall.status))")
                self.onToolCall?(toolCall.title ?? "Tool execution")
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
                // If we have text content, display it
                if !textContent.isEmpty {
                    print("📥 Tool output: \(textContent)")
                    self.onToolUpdate?(toolUpdate.toolCallId.value, textContent)
                } else if let status = toolUpdate.status {
                    // Show status change
                    print("📥 Tool status: \(status)")
                    self.onToolUpdate?(toolUpdate.toolCallId.value, "Status: \(status)")
                }
            default:
                print("📨 Other update: \(update)")
            }
        }
        
        let promptRequest = PromptRequest(
            sessionId: sessionId,
            prompt: [.text(TextContent(text: text))]
        )
        
        print("📤 Prompt request created: \(promptRequest)")
        
        // Send prompt in background - don't block main thread
        Task {
            do {
                let response = try await conn.prompt(request: promptRequest)
                print("📥 Prompt completed: \(response.stopReason)")
                
                // Small delay to ensure final chunks arrive
                try? await Task.sleep(nanoseconds: 100_000_000)
                
                await MainActor.run {
                    onComplete(response.stopReason)
                }
            } catch {
                print("❌ Prompt error: \(error)")
                await MainActor.run {
                    onComplete(nil)
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

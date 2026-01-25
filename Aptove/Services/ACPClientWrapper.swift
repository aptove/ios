import Foundation
import ACP
import ACPHTTP
import ACPModel

/// Client implementation that collects streaming responses
@MainActor
private class AptoveClient: Client, ClientSessionOperations {
    var capabilities: ClientCapabilities {
        ClientCapabilities(terminal: true) // Enable terminal to see if agent calls us
    }
    
    var info: Implementation? {
        Implementation(name: "Aptove", version: "1.0.0")
    }
    
    // Callback to handle session updates
    var onUpdate: ((SessionUpdate) -> Void)?
    
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
    
    let config: ConnectionConfig
    let agentId: String
    let connectionTimeout: TimeInterval
    let maxRetries: Int
    
    private var connection: ClientConnection?
    private var currentSessionId: SessionId?
    private var client: AptoveClient?
    
    // Store for collecting agent responses
    private var currentResponse: String = ""
    
    init(config: ConnectionConfig, agentId: String, connectionTimeout: TimeInterval = 300, maxRetries: Int = 3) {
        self.config = config
        self.agentId = agentId
        self.connectionTimeout = connectionTimeout
        self.maxRetries = maxRetries
    }
    
    func connect() async {
        connectionState = .connecting
        connectionMessage = "Connecting to agent..."
        
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                if attempt > 1 {
                    connectionMessage = "Retrying connection (\(attempt)/\(maxRetries))..."
                    // Wait a bit before retrying
                    try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                }
                
                guard let url = URL(string: config.websocketURL) else {
                    connectionState = .error("Invalid URL")
                    return
                }
                
                // Create URLSession with optional CF-Access headers
                let configuration = URLSessionConfiguration.default
                configuration.timeoutIntervalForRequest = connectionTimeout
                configuration.timeoutIntervalForResource = connectionTimeout
                
                var headers: [String: String] = [:]
                
                // Only add CF-Access headers if credentials are provided
                if let clientId = config.clientId, !clientId.isEmpty {
                    headers["CF-Access-Client-Id"] = clientId
                }
                
                if let clientSecret = config.clientSecret, !clientSecret.isEmpty {
                    headers["CF-Access-Client-Secret"] = clientSecret
                }
                
                if !headers.isEmpty {
                    configuration.httpAdditionalHeaders = headers
                }
                
                let session = URLSession(configuration: configuration)
                
                connectionMessage = "Establishing connection...\nThis may take a moment if authorization is required."
                
                let transport = WebSocketTransport(url: url, session: session)
                let client = AptoveClient()
                self.client = client
                
                // Set up permission request handler
                client.onPermissionRequest = { [weak self] requestId, toolCall, permissions in
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
                let conn = ClientConnection(transport: transport, client: client, defaultTimeoutSeconds: connectionTimeout)
                
                // Connect and initialize with extended timeout
                connectionMessage = "Initializing agent...\nPlease wait, this can take up to \(Int(connectionTimeout)) seconds."
                _ = try await conn.connect()
                
                // Always try to create a session (loadSession:false just means can't load old sessions)
                connectionMessage = "Creating session..."
                print("🔧 Creating session with cwd: \(FileManager.default.currentDirectoryPath)")
                let sessionRequest = NewSessionRequest(
                    cwd: FileManager.default.currentDirectoryPath,
                    mcpServers: []
                )
                let sessionResponse = try await conn.createSession(request: sessionRequest)
                print("✅ Session created with ID: \(sessionResponse.sessionId)")
                self.currentSessionId = sessionResponse.sessionId
                
                self.connection = conn
                connectionMessage = "Connected successfully!"
                connectionState = .connected
                return
                
            } catch {
                lastError = error
                print("Connection attempt \(attempt) failed: \(error.localizedDescription)")
                
                // Continue to retry on errors unless it's the last attempt
                // Some errors like network timeouts may succeed on retry
            }
        }
        
        // All retries failed
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
    var onComplete: ((StopReason) -> Void)?
    var onToolApprovalRequest: ((String, String, String?, [PermissionOption]) -> Void)? // toolCallId, title, command, options
    
    // Store pending tool approval requests
    private var pendingToolRequests: [String: ToolCallUpdateData] = [:] // toolCallId -> ToolCallUpdateData
    
    func sendMessage(_ text: String, onChunk: @escaping (String) -> Void, onComplete: @escaping (StopReason?) -> Void = { _ in }) async throws {
        guard let conn = connection, let sessionId = currentSessionId, let client = client else {
            throw ClientError.noActiveSession
        }
        
        print("📤 Sending prompt to session: \(sessionId.value)")
        print("📤 Message: \(text)")
        
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
                print("🔧 Tool call: \(toolCall.title) - status: \(String(describing: toolCall.status))")
                self.onToolCall?(toolCall.title)
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

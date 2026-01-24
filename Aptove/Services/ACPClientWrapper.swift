import Foundation
import ACP
import ACPHTTP
import ACPModel

/// Simple client implementation for Aptove
private struct AptoveClient: Client {
    var capabilities: ClientCapabilities {
        ClientCapabilities()
    }
    
    var info: Implementation? {
        Implementation(name: "Aptove", version: "1.0.0")
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
    
    let config: ConnectionConfig
    let agentId: String
    
    private var connection: ClientConnection?
    private var currentSessionId: SessionId?
    
    init(config: ConnectionConfig, agentId: String) {
        self.config = config
        self.agentId = agentId
    }
    
    func connect() async {
        connectionState = .connecting
        
        do {
            guard let url = URL(string: config.websocketURL) else {
                connectionState = .error("Invalid URL")
                return
            }
            
            // Create URLSession with CF-Access headers
            let configuration = URLSessionConfiguration.default
            configuration.httpAdditionalHeaders = [
                "CF-Access-Client-Id": config.clientId,
                "CF-Access-Client-Secret": config.clientSecret
            ]
            let session = URLSession(configuration: configuration)
            
            let transport = WebSocketTransport(url: url, session: session)
            let client = AptoveClient()
            let conn = ClientConnection(transport: transport, client: client)
            
            // Connect and initialize
            _ = try await conn.connect()
            
            // Create a session
            let sessionRequest = NewSessionRequest(
                cwd: FileManager.default.currentDirectoryPath,
                mcpServers: []
            )
            let sessionResponse = try await conn.createSession(request: sessionRequest)
            
            self.connection = conn
            self.currentSessionId = sessionResponse.sessionId
            connectionState = .connected
            
        } catch {
            connectionState = .error(error.localizedDescription)
        }
    }
    
    func disconnect() async {
        if let conn = connection {
            try? await conn.disconnect()
            connection = nil
            currentSessionId = nil
        }
        
        connectionState = .disconnected
    }
    
    func sendMessage(_ text: String) async throws -> String {
        guard let conn = connection, let sessionId = currentSessionId else {
            throw ClientError.noActiveSession
        }
        
        let promptRequest = PromptRequest(
            sessionId: sessionId,
            prompt: [.text(TextContent(text: text))]
        )
        
        // Send the prompt - the response comes through session update callbacks
        // For now, we'll just confirm the message was sent
        _ = try await conn.prompt(request: promptRequest)
        
        // TODO: Collect response from session update notifications (agentMessageChunk)
        // This requires implementing proper session update handling in the Client
        return "Message sent successfully"
    }
    
    enum ClientError: LocalizedError {
        case noActiveSession
        case invalidResponse
        
        var errorDescription: String? {
            switch self {
            case .noActiveSession:
                return "No active session"
            case .invalidResponse:
                return "Invalid response from agent"
            }
        }
    }
}

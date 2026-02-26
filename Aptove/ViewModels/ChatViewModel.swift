import Foundation
import SwiftUI

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var isSending = false
    @Published var sessionWasResumed: Bool? = nil  // nil = unknown, true = resumed, false = new
    @Published var showSessionIndicator = false
    
    let agentId: String
    private var agentManager: AgentManager?
    private var isToolApprovalHandlerSetup = false
    private var cachedClient: ACPClientWrapper?
    private var isPrewarmingClient = false
    private var hasShownSessionIndicator = false  // Track if we've already shown the indicator this view session
    
    /// Track active tasks for cleanup
    private var prewarmTask: Task<Void, Never>?
    private var sendMessageTask: Task<Void, Never>?
    
    init(agentId: String) {
        self.agentId = agentId
    }
    
    deinit {
        // Cancel any outstanding tasks
        prewarmTask?.cancel()
        sendMessageTask?.cancel()
    }
    
    func setAgentManager(_ manager: AgentManager) {
        self.agentManager = manager
        print("💬 ChatViewModel: AgentManager set for agent \(agentId)")
        
        // Pre-warm client in background (fire-and-forget, don't await!)
        prewarmClient()
    }
    
    /// Cancel any active operations (call when view disappears)
    func cleanup() {
        prewarmTask?.cancel()
        sendMessageTask?.cancel()
    }
    
    /// Pre-warm the client in background without blocking the main thread
    /// This includes establishing the WebSocket connection so first message is instant
    private func prewarmClient() {
        guard !isPrewarmingClient, cachedClient == nil else { return }
        isPrewarmingClient = true
        
        print("🔥 ChatViewModel: Starting client pre-warm for agent \(agentId)")
        
        // Store task for potential cancellation
        prewarmTask = Task { [weak self, agentManager, agentId] in
            print("🔥 ChatViewModel: Pre-warm task started")
            
            // Check for cancellation before expensive operations
            guard !Task.isCancelled else {
                print("🔥 ChatViewModel: Pre-warm cancelled before getClient")
                return
            }
            
            // Use getConnectedClient which handles session persistence
            let client = await agentManager?.getConnectedClient(for: agentId)
            print("🔥 ChatViewModel: Pre-warm got client: \(client != nil)")
            
            // Check for cancellation before updating state
            guard !Task.isCancelled else {
                print("🔥 ChatViewModel: Pre-warm cancelled before state update")
                return
            }
            
            // Update cached client and set up tool handler
            guard let self = self else { return }
            self.cachedClient = client
            self.isPrewarmingClient = false
            
            if let client = client {
                print("🔥 ChatViewModel: Pre-warm complete, client cached, state: \(client.connectionState)")
                
                // Only show session indicator on fresh connections, not when returning to an already-connected session
                // sessionWasResumed is nil until the first connect() call completes
                if let wasResumed = client.sessionWasResumed, !self.hasShownSessionIndicator {
                    self.sessionWasResumed = wasResumed
                    self.showSessionIndicator = true
                    self.hasShownSessionIndicator = true
                    // Hide indicator after 3 seconds
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        self.showSessionIndicator = false
                    }
                }
                
                // Set up tool approval handler now that we have the client
                if !self.isToolApprovalHandlerSetup {
                    self.setupToolApprovalHandlerSync(client: client)
                }
            } else {
                print("🔥 ChatViewModel: Pre-warm complete but no client")
            }
        }
    }
    
    /// Synchronous version of tool approval handler setup (call from MainActor)
    private func setupToolApprovalHandlerSync(client: ACPClientWrapper) {
        guard !isToolApprovalHandlerSetup else { return }
        isToolApprovalHandlerSetup = true
        
        print("💬 ChatViewModel: Setting up tool approval handler for agent \(agentId)")
        client.onToolApprovalRequest = { [weak self] toolCallId, title, command, permissions in
            Task { @MainActor in
                guard let self = self else { return }
                
                let commandText = command.map { "\n\n`\($0)`" } ?? ""
                
                // Convert permissions to PermissionOptionInfo
                let options = permissions.map { permission in
                    PermissionOptionInfo(
                        optionId: permission.optionId.value,
                        name: permission.name,
                        kind: permission.kind.rawValue
                    )
                }
                
                let approvalMessage = Message(
                    text: "⚠️ **Permission Required**\n\n\(title)\(commandText)",
                    sender: .agent,
                    status: .sent,
                    type: .toolApprovalRequest,
                    toolApproval: ToolApprovalInfo(
                        toolCallId: toolCallId,
                        title: title,
                        command: command,
                        options: options
                    )
                )
                
                self.messages.append(approvalMessage)
                self.updateConversation()
            }
        }
    }
    
    private func setupToolApprovalHandler() async {
        // Only set up once
        guard !isToolApprovalHandlerSetup else { return }
        
        // Use cached client or get it (should be pre-warmed by now)
        let client: ACPClientWrapper?
        if let cached = cachedClient {
            client = cached
            print("💬 ChatViewModel: Using pre-warmed client for tool approval handler")
        } else {
            print("💬 ChatViewModel: Client not pre-warmed, getting now...")
            client = await agentManager?.getClient(for: agentId)
        }
        
        guard let client = client else { return }
        
        setupToolApprovalHandlerSync(client: client)
    }
    
    func loadMessages() {
        guard let conversation = agentManager?.conversations[agentId] else {
            return
        }
        messages = conversation.messages
    }
    
    func sendMessage(_ text: String) async {
        print("📤 ChatViewModel.sendMessage: Starting...")
        isSending = true
        
        let userMessage = Message(
            text: text,
            sender: .user,
            status: .sending
        )
        
        messages.append(userMessage)
        updateConversation()
        
        // Use cached client if available (should be pre-warmed)
        let client: ACPClientWrapper?
        if let cached = cachedClient {
            print("📤 ChatViewModel.sendMessage: Using pre-warmed client")
            client = cached
        } else {
            print("📤 ChatViewModel.sendMessage: Client not pre-warmed, getting connected client now...")
            // Use getConnectedClient which handles session persistence
            client = await agentManager?.getConnectedClient(for: agentId)
            cachedClient = client
        }
        
        guard let client = client else {
            print("❌ ChatViewModel.sendMessage: No client available")
            updateMessageStatus(userMessage.id, to: .error)
            isSending = false
            return
        }
        
        // Set up tool approval handler lazily on first message
        if !isToolApprovalHandlerSetup {
            await setupToolApprovalHandler()
        }
        
        // Only connect if not already connected (getConnectedClient should handle this but double-check)
        if case .connected = client.connectionState {
            // Already connected, continue
        } else {
            // Need to connect - use AgentManager to handle session persistence
            if let manager = agentManager {
                let existingSessionId = manager.agents.first(where: { $0.id == agentId })?.activeSessionId
                await client.connect(existingSessionId: existingSessionId)
                
                // Update session info after connection
                if case .connected = client.connectionState {
                    manager.updateAgentSessionInfo(
                        agentId: agentId,
                        sessionId: client.sessionId,
                        supportsLoadSession: client.supportsLoadSession
                    )
                }
            } else {
                await client.connect()
            }
            
            // Check if connection was successful
            guard case .connected = client.connectionState else {
                let errorMsg = if case .error(let msg) = client.connectionState {
                    msg
                } else {
                    "Failed to connect to agent"
                }
                
                updateMessageStatus(userMessage.id, to: .error)
                
                let errorMessage = Message(
                    text: "Connection error: \(errorMsg)",
                    sender: .agent,
                    status: .error,
                    type: .text
                )
                
                messages.append(errorMessage)
                updateConversation()
                isSending = false
                return
            }
        }
        
        do {
            // Create agent message that will be updated incrementally
            let agentMessage = Message(
                text: "",
                sender: .agent,
                status: .sending,
                type: .text
            )
            messages.append(agentMessage)
            let agentMessageIndex = messages.count - 1
            var accumulatedText = "" // Track accumulated text separately
            var currentThoughtId: String? = nil // Track current thought message
            var currentToolId: String? = nil // Track current tool message
            var toolOutputMessages: [String: String] = [:] // Track tool output messages by toolCallId
            updateConversation()
            
            // Send message with streaming callbacks
            try await client.sendMessage(text,
                onChunk: { chunk in
                    // Update agent message incrementally on main thread
                    Task { @MainActor in
                        accumulatedText += chunk
                        if agentMessageIndex < self.messages.count {
                            self.messages[agentMessageIndex] = Message(
                                id: agentMessage.id,
                                text: accumulatedText,
                                sender: .agent,
                                status: .sending,
                                type: .text
                            )
                            self.updateConversation()
                        }
                    }
                },
                onThought: { thought in
                    // Display thought message
                    Task { @MainActor in
                        if let thinkingId = currentThoughtId,
                           let index = self.messages.firstIndex(where: { $0.id == thinkingId }) {
                            // Update existing thought message
                            self.messages[index] = Message(
                                id: thinkingId,
                                text: thought,
                                sender: .agent,
                                status: .sent,
                                type: .thought,
                                isThinking: true
                            )
                        } else {
                            // Create new thought message
                            let thinkingMsg = Message(
                                text: thought,
                                sender: .agent,
                                status: .sent,
                                type: .thought,
                                isThinking: true
                            )
                            self.messages.append(thinkingMsg)
                            currentThoughtId = thinkingMsg.id
                        }
                        self.updateConversation()
                    }
                },
                onToolCall: { toolTitle in
                    // Display tool status message
                    Task { @MainActor in
                        if let toolId = currentToolId,
                           let index = self.messages.firstIndex(where: { $0.id == toolId }) {
                            // Update existing tool message
                            self.messages[index] = Message(
                                id: toolId,
                                text: toolTitle,
                                sender: .agent,
                                status: .sent,
                                type: .toolStatus
                            )
                        } else {
                            // Create new tool message
                            let toolMsg = Message(
                                text: toolTitle,
                                sender: .agent,
                                status: .sent,
                                type: .toolStatus
                            )
                            self.messages.append(toolMsg)
                            currentToolId = toolMsg.id
                        }
                        self.updateConversation()
                    }
                },
                onToolUpdate: { toolCallId, content in
                    // Display or update tool output message
                    Task { @MainActor in
                        // Check if we already have a message for this tool
                        if let existingMsgId = toolOutputMessages[toolCallId],
                           let index = self.messages.firstIndex(where: { $0.id == existingMsgId }) {
                            // Update existing tool output message
                            let existingText = self.messages[index].text
                            self.messages[index] = Message(
                                id: existingMsgId,
                                text: existingText + "\n" + content,
                                sender: .agent,
                                status: .sent,
                                type: .toolStatus
                            )
                        } else {
                            // Create new tool output message
                            let toolOutputMsg = Message(
                                text: content,
                                sender: .agent,
                                status: .sent,
                                type: .toolStatus
                            )
                            self.messages.append(toolOutputMsg)
                            toolOutputMessages[toolCallId] = toolOutputMsg.id
                        }
                        self.updateConversation()
                    }
                },
                onComplete: { stopReason in
                    // Mark messages as complete
                    Task { @MainActor in
                        self.updateMessageStatus(userMessage.id, to: .sent)
                        
                        if agentMessageIndex < self.messages.count {
                            // If agent message is empty, it might be a tool-only response
                            let finalText = accumulatedText.isEmpty ? (stopReason == nil ? "Request failed" : "(No response received)") : accumulatedText
                            
                            self.messages[agentMessageIndex] = Message(
                                id: self.messages[agentMessageIndex].id,
                                text: finalText,
                                sender: .agent,
                                status: stopReason != nil ? .sent : .error,
                                type: .text
                            )
                            self.updateConversation()
                        }
                        
                        self.isSending = false
                    }
                }
            )
            
        } catch {
            updateMessageStatus(userMessage.id, to: .error)
            
            let errorMessage = Message(
                text: "Error: \(error.localizedDescription)",
                sender: .agent,
                status: .error,
                type: .text
            )
            
            messages.append(errorMessage)
            updateConversation()
            isSending = false
        }
        
        isSending = false
    }
    
    private func updateMessageStatus(_ messageId: String, to status: MessageStatus) {
        if let index = messages.firstIndex(where: { $0.id == messageId }) {
            let msg = messages[index]
            messages[index] = Message(
                id: msg.id,
                text: msg.text,
                sender: msg.sender,
                timestamp: msg.timestamp,
                status: status,
                type: msg.type,
                toolApproval: msg.toolApproval
            )
            updateConversation()
        }
    }
    
    func approveTool(messageId: String, optionId: String = "allow_once") async {
        guard let message = messages.first(where: { $0.id == messageId }),
              let toolApproval = message.toolApproval else {
            return
        }
        
        // Use cached client
        guard let client = cachedClient else { return }
        
        do {
            try await client.approveTool(toolCallId: toolApproval.toolCallId, optionId: optionId)
            
            // Update message to show approval
            if let index = messages.firstIndex(where: { $0.id == messageId }) {
                var updatedApproval = toolApproval
                updatedApproval = ToolApprovalInfo(
                    toolCallId: toolApproval.toolCallId,
                    title: toolApproval.title,
                    command: toolApproval.command,
                    approved: true,
                    options: toolApproval.options
                )
                
                messages[index] = Message(
                    id: message.id,
                    text: message.text,
                    sender: message.sender,
                    timestamp: message.timestamp,
                    status: .sent,
                    type: message.type,
                    toolApproval: updatedApproval
                )
                updateConversation()
            }
        } catch {
            print("Error approving tool: \(error)")
        }
    }
    
    func rejectTool(messageId: String) async {
        guard let message = messages.first(where: { $0.id == messageId }),
              let toolApproval = message.toolApproval else {
            return
        }
        
        // Use cached client
        guard let client = cachedClient else { return }
        
        do {
            try await client.rejectTool(toolCallId: toolApproval.toolCallId)
            
            // Update message to show rejection
            if let index = messages.firstIndex(where: { $0.id == messageId }) {
                var updatedApproval = toolApproval
                updatedApproval = ToolApprovalInfo(
                    toolCallId: toolApproval.toolCallId,
                    title: toolApproval.title,
                    command: toolApproval.command,
                    approved: false,
                    options: toolApproval.options
                )
                
                messages[index] = Message(
                    id: message.id,
                    text: message.text,
                    sender: message.sender,
                    timestamp: message.timestamp,
                    status: .sent,
                    type: message.type,
                    toolApproval: updatedApproval
                )
                updateConversation()
            }
        } catch {
            print("Error rejecting tool: \(error)")
        }
    }
    
    private func updateConversation() {
        guard let manager = agentManager else { return }
        
        var conversation = manager.conversations[agentId] ?? Conversation(agentId: agentId)
        conversation.messages = messages
        conversation.lastActivity = Date()
        
        manager.conversations[agentId] = conversation
        manager.sortAgents()
    }
}

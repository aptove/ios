import Foundation
import SwiftUI

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var isSending = false
    
    let agentId: String
    private var agentManager: AgentManager?
    
    init(agentId: String) {
        self.agentId = agentId
    }
    
    func setAgentManager(_ manager: AgentManager) {
        self.agentManager = manager
        
        // Set up tool approval handler once during initialization
        if let client = manager.getClient(for: agentId) {
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
    }
    
    func loadMessages() {
        guard let conversation = agentManager?.conversations[agentId] else {
            return
        }
        messages = conversation.messages
    }
    
    func sendMessage(_ text: String) async {
        isSending = true
        
        let userMessage = Message(
            text: text,
            sender: .user,
            status: .sending
        )
        
        messages.append(userMessage)
        updateConversation()
        
        guard let client = agentManager?.getClient(for: agentId) else {
            updateMessageStatus(userMessage.id, to: .error)
            isSending = false
            return
        }
        
        // Only connect if not already connected
        if case .connected = client.connectionState {
            // Already connected, continue
        } else {
            // Need to connect
            await client.connect()
            
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
            var agentMessage = Message(
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
                            let finalText = accumulatedText.isEmpty ? (stopReason == nil ? "Request failed" : "(Tool execution pending or cancelled)") : accumulatedText
                            
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
              let toolApproval = message.toolApproval,
              let client = agentManager?.getClient(for: agentId) else {
            return
        }
        
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
              let toolApproval = message.toolApproval,
              let client = agentManager?.getClient(for: agentId) else {
            return
        }
        
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

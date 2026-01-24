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
        
        await client.connect()
        
        do {
            let response = try await client.sendMessage(text)
            
            updateMessageStatus(userMessage.id, to: .sent)
            
            let agentMessage = Message(
                text: response,
                sender: .agent,
                status: .sent
            )
            
            messages.append(agentMessage)
            updateConversation()
            
        } catch {
            updateMessageStatus(userMessage.id, to: .error)
            
            let errorMessage = Message(
                text: "Error: \(error.localizedDescription)",
                sender: .agent,
                status: .error
            )
            
            messages.append(errorMessage)
            updateConversation()
        }
        
        isSending = false
    }
    
    private func updateMessageStatus(_ messageId: String, to status: MessageStatus) {
        if let index = messages.firstIndex(where: { $0.id == messageId }) {
            messages[index] = Message(
                id: messages[index].id,
                text: messages[index].text,
                sender: messages[index].sender,
                timestamp: messages[index].timestamp,
                status: status
            )
            updateConversation()
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

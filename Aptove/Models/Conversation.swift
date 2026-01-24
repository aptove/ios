import Foundation

struct Conversation: Codable {
    let agentId: String
    var messages: [Message]
    var unreadCount: Int
    var lastActivity: Date
    
    init(agentId: String, messages: [Message] = [], unreadCount: Int = 0, lastActivity: Date = Date()) {
        self.agentId = agentId
        self.messages = messages
        self.unreadCount = unreadCount
        self.lastActivity = lastActivity
    }
}

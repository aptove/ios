import Foundation

enum MessageSender: String, Codable {
    case user
    case agent
}

enum MessageStatus: String, Codable {
    case sending
    case sent
    case error
}

enum MessageType: String, Codable {
    case text
    case toolApprovalRequest
}

struct ToolApprovalInfo: Codable {
    let toolCallId: String
    let title: String
    let command: String?
    let approved: Bool?
    
    init(toolCallId: String, title: String, command: String?, approved: Bool? = nil) {
        self.toolCallId = toolCallId
        self.title = title
        self.command = command
        self.approved = approved
    }
}

struct Message: Identifiable, Codable {
    let id: String
    let text: String
    let sender: MessageSender
    let timestamp: Date
    var status: MessageStatus
    let type: MessageType
    let toolApproval: ToolApprovalInfo?
    
    init(id: String = UUID().uuidString, text: String, sender: MessageSender, timestamp: Date = Date(), status: MessageStatus = .sent, type: MessageType = .text, toolApproval: ToolApprovalInfo? = nil) {
        self.id = id
        self.text = text
        self.sender = sender
        self.timestamp = timestamp
        self.status = status
        self.type = type
        self.toolApproval = toolApproval
    }
}

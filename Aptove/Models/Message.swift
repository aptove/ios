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

struct Message: Identifiable, Codable {
    let id: String
    let text: String
    let sender: MessageSender
    let timestamp: Date
    var status: MessageStatus
    
    init(id: String = UUID().uuidString, text: String, sender: MessageSender, timestamp: Date = Date(), status: MessageStatus = .sent) {
        self.id = id
        self.text = text
        self.sender = sender
        self.timestamp = timestamp
        self.status = status
    }
}

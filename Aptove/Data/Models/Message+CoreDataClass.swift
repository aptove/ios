//  Message+CoreDataClass.swift
//

import Foundation
import CoreData

@objc(Message)
public class Message: NSManagedObject {
    /// Convenience initializer
    convenience init(context: NSManagedObjectContext,
                    messageId: String,
                    agentId: String,
                    role: String,
                    content: String) {
        self.init(context: context)
        self.messageId = messageId
        self.agentId = agentId
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.isError = false
    }
}

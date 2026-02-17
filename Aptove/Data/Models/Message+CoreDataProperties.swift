//  Message+CoreDataProperties.swift
//

import Foundation
import CoreData

extension MessageEntity {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<MessageEntity> {
        return NSFetchRequest<MessageEntity>(entityName: "Message")
    }

    // MARK: - Primary Key
    @NSManaged public var messageId: String?

    // MARK: - Foreign Key
    @NSManaged public var agentId: String?

    // MARK: - Message Data
    @NSManaged public var role: String?
    @NSManaged public var content: String?
    @NSManaged public var timestamp: Date?
    @NSManaged public var isError: Bool

    // MARK: - Relationships
    @NSManaged public var agent: AgentEntity?
}

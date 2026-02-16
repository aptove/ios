//  Agent+CoreDataProperties.swift
//

import Foundation
import CoreData

extension Agent {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<Agent> {
        return NSFetchRequest<Agent>(entityName: "Agent")
    }

    // MARK: - Primary Key
    @NSManaged public var agentId: String?

    // MARK: - Basic Info
    @NSManaged public var name: String?
    @NSManaged public var agentDescription: String?
    @NSManaged public var url: String?
    @NSManaged public var protocolVersion: String?

    // MARK: - JSON Data
    @NSManaged public var capabilities: String?

    // MARK: - Status
    @NSManaged public var connectionStatus: String?
    @NSManaged public var lastConnectedAt: Date?
    @NSManaged public var createdAt: Date?
    @NSManaged public var colorHue: Float

    // MARK: - Session Persistence
    @NSManaged public var activeSessionId: String?
    @NSManaged public var sessionStartedAt: Date?
    @NSManaged public var supportsLoadSession: Bool

    // MARK: - Relationships
    @NSManaged public var messages: NSSet?
}

// MARK: - Generated accessors for messages
extension Agent {

    @objc(addMessagesObject:)
    @NSManaged public func addToMessages(_ value: Message)

    @objc(removeMessagesObject:)
    @NSManaged public func removeFromMessages(_ value: Message)

    @objc(addMessages:)
    @NSManaged public func addToMessages(_ values: NSSet)

    @objc(removeMessages:)
    @NSManaged public func removeFromMessages(_ values: NSSet)
}

extension Agent : Identifiable {
    public var id: String {
        return agentId ?? UUID().uuidString
    }
}

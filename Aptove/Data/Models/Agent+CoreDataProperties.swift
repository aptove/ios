//  Agent+CoreDataProperties.swift
//

import Foundation
import CoreData

extension AgentEntity {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<AgentEntity> {
        return NSFetchRequest<AgentEntity>(entityName: "Agent")
    }

    // MARK: - Primary Key
    @NSManaged public var agentId: String?

    // MARK: - Basic Info
    @NSManaged public var name: String?
    @NSManaged public var agentDescription: String?
    @NSManaged public var url: String?
    @NSManaged public var protocolVersion: String?

    // MARK: - Bridge Identity
    /// Stable UUID from the bridge, used to deduplicate agents across multiple transports.
    @NSManaged public var bridgeAgentId: String?
    /// User-selected preferred transport name (e.g. "tailscale-serve", "cloudflare", "local").
    @NSManaged public var preferredTransport: String?

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
    @NSManaged public var endpoints: NSSet?
}

// MARK: - Generated accessors for messages
extension AgentEntity {

    @objc(addMessagesObject:)
    @NSManaged public func addToMessages(_ value: MessageEntity)

    @objc(removeMessagesObject:)
    @NSManaged public func removeFromMessages(_ value: MessageEntity)

    @objc(addMessages:)
    @NSManaged public func addToMessages(_ values: NSSet)

    @objc(removeMessages:)
    @NSManaged public func removeFromMessages(_ values: NSSet)
}

// MARK: - Generated accessors for endpoints
extension AgentEntity {

    @objc(addEndpointsObject:)
    @NSManaged public func addToEndpoints(_ value: TransportEndpointEntity)

    @objc(removeEndpointsObject:)
    @NSManaged public func removeFromEndpoints(_ value: TransportEndpointEntity)

    @objc(addEndpoints:)
    @NSManaged public func addToEndpoints(_ values: NSSet)

    @objc(removeEndpoints:)
    @NSManaged public func removeFromEndpoints(_ values: NSSet)

    /// Returns endpoints sorted by priority (ascending — lower number = higher priority).
    var sortedEndpoints: [TransportEndpointEntity] {
        let set = endpoints as? Set<TransportEndpointEntity> ?? []
        return set.sorted { $0.priority < $1.priority }
    }
}

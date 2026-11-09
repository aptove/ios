//  MessageRepository.swift
//

import Foundation
import CoreData

/// Extra fields that can't be mapped to first-class CoreData columns.
/// `isThinking` is intentionally excluded — it reflects live streaming state only.
struct MessageExtra: Codable {
    var type: String       // MessageType raw value
    var status: String     // MessageStatus raw value
    var toolApproval: ToolApprovalInfo?
}

struct StarredMessage: Identifiable {
    var id: String { message.id }
    let message: Message
    let agentId: String
    let agentName: String
}

class MessageRepository {
    private let stack: CoreDataStack

    init(stack: CoreDataStack = .shared) {
        self.stack = stack
    }

    // MARK: - Fetch

    /// Returns all persisted messages for an agent, ordered by timestamp ascending.
    func fetchMessages(agentId: String) -> [Message] {
        let request = MessageEntity.fetchRequest()
        request.predicate = NSPredicate(format: "agentId == %@", agentId)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \MessageEntity.timestamp, ascending: true)]

        do {
            let entities = try stack.viewContext.fetch(request)
            return entities.compactMap { toModel($0) }
        } catch {
            print("❌ MessageRepository: Failed to fetch messages for \(agentId): \(error)")
            return []
        }
    }

    // MARK: - Save

    /// Upserts all messages for an agent. Existing entities are updated; new ones are inserted.
    func saveMessages(_ messages: [Message], agentId: String, agent: AgentEntity) {
        let context = stack.viewContext

        // Pre-fetch existing entities keyed by messageId for O(1) lookup
        let request = MessageEntity.fetchRequest()
        request.predicate = NSPredicate(format: "agentId == %@", agentId)
        let existing: [String: MessageEntity]
        do {
            let entities = try context.fetch(request)
            existing = Dictionary(uniqueKeysWithValues: entities.compactMap { e in
                guard let mid = e.messageId else { return nil }
                return (mid, e)
            })
        } catch {
            print("❌ MessageRepository: Failed to pre-fetch for upsert: \(error)")
            return
        }

        for message in messages {
            let entity = existing[message.id] ?? MessageEntity(context: context)
            populate(entity: entity, from: message, agentId: agentId, agent: agent)
        }

        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            print("❌ MessageRepository: Failed to save messages: \(error)")
        }
    }

    // MARK: - Star

    /// Fetches all starred messages across all agents, sorted by timestamp descending.
    func fetchStarredMessages() -> [StarredMessage] {
        let request = MessageEntity.fetchRequest()
        request.predicate = NSPredicate(format: "isStarred == YES")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \MessageEntity.timestamp, ascending: false)]

        do {
            let entities = try stack.viewContext.fetch(request)
            return entities.compactMap { entity in
                guard let agentId = entity.agentId,
                      let message = toModel(entity) else { return nil }
                let agentName = entity.agent?.name ?? agentId
                return StarredMessage(message: message, agentId: agentId, agentName: agentName)
            }
        } catch {
            print("❌ MessageRepository: Failed to fetch starred messages: \(error)")
            return []
        }
    }

    /// Sets the starred state of a single message by messageId.
    func setStarred(messageId: String, isStarred: Bool) {
        let context = stack.viewContext
        let request = MessageEntity.fetchRequest()
        request.predicate = NSPredicate(format: "messageId == %@", messageId)

        guard let entity = try? context.fetch(request).first else { return }
        entity.isStarred = isStarred
        if context.hasChanges {
            try? context.save()
        }
    }

    // MARK: - Delete

    /// Deletes all persisted messages for an agent (called on Clear Session / credential update).
    func deleteMessages(agentId: String) {
        let context = stack.viewContext
        let request = MessageEntity.fetchRequest()
        request.predicate = NSPredicate(format: "agentId == %@", agentId)

        do {
            let entities = try context.fetch(request)
            entities.forEach { context.delete($0) }
            if context.hasChanges {
                try context.save()
            }
            print("🗑️ MessageRepository: Deleted messages for \(agentId)")
        } catch {
            print("❌ MessageRepository: Failed to delete messages for \(agentId): \(error)")
        }
    }

    // MARK: - Private helpers

    private func populate(entity: MessageEntity, from message: Message, agentId: String, agent: AgentEntity) {
        entity.messageId = message.id
        entity.agentId = agentId
        entity.content = message.text
        entity.role = message.sender.rawValue
        entity.timestamp = message.timestamp
        entity.agent = agent
        entity.isStarred = message.isStarred

        let extra = MessageExtra(
            type: message.type.rawValue,
            status: message.status.rawValue,
            toolApproval: message.toolApproval
        )
        entity.extraData = try? JSONEncoder().encode(extra)
    }

    private func toModel(_ entity: MessageEntity) -> Message? {
        guard let messageId = entity.messageId,
              let content = entity.content,
              let roleRaw = entity.role,
              let sender = MessageSender(rawValue: roleRaw),
              let timestamp = entity.timestamp
        else { return nil }

        var type: MessageType = .text
        var status: MessageStatus = .sent
        var toolApproval: ToolApprovalInfo? = nil

        if let data = entity.extraData,
           let extra = try? JSONDecoder().decode(MessageExtra.self, from: data) {
            type = MessageType(rawValue: extra.type) ?? .text
            status = MessageStatus(rawValue: extra.status) ?? .sent
            toolApproval = extra.toolApproval
        }

        return Message(
            id: messageId,
            text: content,
            sender: sender,
            timestamp: timestamp,
            status: status,
            type: type,
            toolApproval: toolApproval,
            isThinking: false,  // transient — always false when loaded
            isStarred: entity.isStarred
        )
    }
}

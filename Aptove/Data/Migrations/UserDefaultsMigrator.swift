//  UserDefaultsMigrator.swift
//

import Foundation
import CoreData
import os

/// Handles one-time migration from UserDefaults to CoreData
class UserDefaultsMigrator {
    private let coreDataStack: CoreDataStack
    private let userDefaults: UserDefaults
    private let repository: AgentRepository

    private static let migrationCompleteKey = "coredata_migration_complete"
    private static let agentsKey = "agents"
    private static let sessionIdKeyPrefix = "aptove.sessionId."

    init(coreDataStack: CoreDataStack = .shared,
         userDefaults: UserDefaults = .standard,
         repository: AgentRepository) {
        self.coreDataStack = coreDataStack
        self.userDefaults = userDefaults
        self.repository = repository
    }

    // MARK: - Public API

    /// Check if migration is needed
    func needsMigration() -> Bool {
        if userDefaults.bool(forKey: Self.migrationCompleteKey) {
            Logger.data.debug("Already migrated to CoreData")
            return false
        }

        let hasUserDefaultsData = userDefaults.data(forKey: Self.agentsKey) != nil
        let coreDataEmpty = repository.fetchAgents().isEmpty

        let needsMigration = hasUserDefaultsData && coreDataEmpty

        if needsMigration {
            Logger.data.debug("Migration needed (UserDefaults has data, CoreData is empty)")
        } else if !hasUserDefaultsData {
            Logger.data.debug("No UserDefaults data to migrate")
        } else if !coreDataEmpty {
            Logger.data.debug("CoreData already has data")
        }

        return needsMigration
    }

    /// Perform migration from UserDefaults to CoreData
    func migrate() throws {
        Logger.data.debug("Starting migration from UserDefaults to CoreData...")

        let backupKey = backupUserDefaults()

        guard let data = userDefaults.data(forKey: Self.agentsKey) else {
            throw MigrationError.noData
        }

        let savedAgents: [LegacySavedAgent]
        do {
            savedAgents = try JSONDecoder().decode([LegacySavedAgent].self, from: data)
            Logger.data.debug("Loaded \(savedAgents.count) agents from UserDefaults")
        } catch {
            Logger.data.error("Failed to decode agents: \(error)")
            throw MigrationError.decodingFailed(error)
        }

        // 3. Create CoreData entities
        let context = coreDataStack.newBackgroundContext()
        var migratedCount = 0

        try context.performAndWait {
            for savedAgent in savedAgents {
                // Create AgentEntity
                let entity = AgentEntity(context: context,
                                agentId: savedAgent.id,
                                name: savedAgent.name,
                                url: savedAgent.config.url,
                                protocolVersion: savedAgent.config.version)

                // Set optional fields
                if let description = savedAgent.agentDescription {
                    entity.agentDescription = description
                }

                // Migrate session ID
                let sessionIdKey = "\(Self.sessionIdKeyPrefix)\(savedAgent.id)"
                if let sessionId = userDefaults.string(forKey: sessionIdKey) {
                    entity.activeSessionId = sessionId
                    entity.sessionStartedAt = Date()
                    Logger.data.debug("Migrated session ID for \(savedAgent.name)")
                }

                migratedCount += 1
            }

            // Save all agents
            do {
                try context.save()
                Logger.data.debug("Successfully migrated \(migratedCount) agents to CoreData")
            } catch {
                Logger.data.error("Failed to save CoreData context: \(error)")
                throw MigrationError.saveFailed(error)
            }
        }

        // 4. Mark migration complete
        userDefaults.set(true, forKey: Self.migrationCompleteKey)
        userDefaults.synchronize()

        // 5. Remove the backup now that migration succeeded — it held no credentials,
        //    but there is no reason to keep it around indefinitely.
        if let key = backupKey {
            userDefaults.removeObject(forKey: key)
            Logger.data.debug("Removed migration backup after successful migration")
        }

        Logger.data.debug("Migration complete.")
    }

    /// Rollback migration (for testing)
    func rollback() {
        userDefaults.removeObject(forKey: Self.migrationCompleteKey)
        Logger.data.debug("Rollback complete — migration flag cleared")
    }

    // MARK: - Private Helpers

    /// Creates a sanitized backup of the legacy agent list, stripping all credentials
    /// (authToken, clientSecret, certificateFingerprint) so the backup is safe to store
    /// in UserDefaults. Returns the backup key so the caller can delete it after migration.
    @discardableResult
    private func backupUserDefaults() -> String? {
        guard let data = userDefaults.data(forKey: Self.agentsKey),
              let agents = try? JSONDecoder().decode([LegacySavedAgent].self, from: data)
        else { return nil }

        // Strip credentials — the backup preserves structure/names for recovery only
        let sanitized = agents.map { agent in
            LegacySavedAgent(
                id: agent.id,
                name: agent.name,
                config: LegacyConnectionConfig(
                    url: agent.config.url,
                    version: agent.config.version,
                    authToken: nil,
                    clientId: nil,
                    clientSecret: nil,
                    certificateFingerprint: nil
                ),
                agentDescription: agent.agentDescription
            )
        }
        guard let sanitizedData = try? JSONEncoder().encode(sanitized) else { return nil }

        let backupKey = "\(Self.agentsKey)_backup_\(Date().timeIntervalSince1970)"
        userDefaults.set(sanitizedData, forKey: backupKey)
        Logger.data.debug("Backed up sanitized agent list to key: \(backupKey)")
        return backupKey
    }
}

// MARK: - Migration Errors

enum MigrationError: LocalizedError {
    case noData
    case decodingFailed(Error)
    case saveFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noData:
            return "No data found in UserDefaults to migrate"
        case .decodingFailed(let error):
            return "Failed to decode UserDefaults data: \(error.localizedDescription)"
        case .saveFailed(let error):
            return "Failed to save CoreData: \(error.localizedDescription)"
        }
    }
}

// MARK: - Legacy Data Models

/// Legacy SavedAgent structure from UserDefaults (for migration only)
struct LegacySavedAgent: Codable {
    let id: String
    let name: String
    let config: LegacyConnectionConfig
    let agentDescription: String?

    enum CodingKeys: String, CodingKey {
        case id, name, config
        case agentDescription = "description"
    }
}

/// Legacy ConnectionConfig structure (for migration decoding only)
/// Note: matches the old JSON shape stored in UserDefaults, not the current ConnectionConfig
struct LegacyConnectionConfig: Codable {
    let url: String
    let version: String
    let authToken: String?
    let clientId: String?
    let clientSecret: String?
    let certificateFingerprint: String?
}

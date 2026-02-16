//  UserDefaultsMigrator.swift
//

import Foundation
import CoreData

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
        // Already migrated?
        if userDefaults.bool(forKey: Self.migrationCompleteKey) {
            print("ℹ️ Migration: Already migrated to CoreData")
            return false
        }

        // Has UserDefaults data?
        let hasUserDefaultsData = userDefaults.data(forKey: Self.agentsKey) != nil

        // Is CoreData empty?
        let coreDataEmpty = repository.fetchAgents().isEmpty

        let needsMigration = hasUserDefaultsData && coreDataEmpty

        if needsMigration {
            print("🔄 Migration: Migration needed (UserDefaults has data, CoreData is empty)")
        } else if !hasUserDefaultsData {
            print("ℹ️ Migration: No UserDefaults data to migrate")
        } else if !coreDataEmpty {
            print("ℹ️ Migration: CoreData already has data")
        }

        return needsMigration
    }

    /// Perform migration from UserDefaults to CoreData
    func migrate() throws {
        print("🚀 Migration: Starting migration from UserDefaults to CoreData...")

        // 1. Backup UserDefaults (for safety)
        backupUserDefaults()

        // 2. Load agents from UserDefaults
        guard let data = userDefaults.data(forKey: Self.agentsKey) else {
            throw MigrationError.noData
        }

        let savedAgents: [SavedAgent]
        do {
            savedAgents = try JSONDecoder().decode([SavedAgent].self, from: data)
            print("📦 Migration: Loaded \(savedAgents.count) agents from UserDefaults")
        } catch {
            print("❌ Migration: Failed to decode agents: \(error)")
            throw MigrationError.decodingFailed(error)
        }

        // 3. Create CoreData entities
        let context = coreDataStack.newBackgroundContext()
        var migratedCount = 0

        try context.performAndWait {
            for savedAgent in savedAgents {
                // Create Agent entity
                let agent = Agent(context: context,
                                agentId: savedAgent.id,
                                name: savedAgent.name,
                                url: savedAgent.config.url,
                                protocolVersion: savedAgent.config.version)

                // Set optional fields
                if let description = savedAgent.agentDescription {
                    agent.agentDescription = description
                }

                // Migrate session ID
                let sessionIdKey = "\(Self.sessionIdKeyPrefix)\(savedAgent.id)"
                if let sessionId = userDefaults.string(forKey: sessionIdKey) {
                    agent.activeSessionId = sessionId
                    agent.sessionStartedAt = Date()
                    print("  📝 Migrated session ID for \(savedAgent.name): \(sessionId)")
                }

                migratedCount += 1
            }

            // Save all agents
            do {
                try context.save()
                print("✅ Migration: Successfully migrated \(migratedCount) agents to CoreData")
            } catch {
                print("❌ Migration: Failed to save CoreData context: \(error)")
                throw MigrationError.saveFailed(error)
            }
        }

        // 4. Mark migration complete
        userDefaults.set(true, forKey: Self.migrationCompleteKey)
        userDefaults.synchronize()

        print("🎉 Migration: Migration complete! UserDefaults data preserved for safety.")
    }

    /// Rollback migration (for testing)
    func rollback() {
        userDefaults.removeObject(forKey: Self.migrationCompleteKey)
        print("🔙 Migration: Rollback complete - migration flag cleared")
    }

    // MARK: - Private Helpers

    private func backupUserDefaults() {
        guard let data = userDefaults.data(forKey: Self.agentsKey) else { return }

        let backupKey = "\(Self.agentsKey)_backup_\(Date().timeIntervalSince1970)"
        userDefaults.set(data, forKey: backupKey)
        print("💾 Migration: Backed up UserDefaults to key: \(backupKey)")
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

/// Legacy SavedAgent structure from UserDefaults (for migration)
struct SavedAgent: Codable {
    let id: String
    let name: String
    let config: ConnectionConfig
    let agentDescription: String?

    enum CodingKeys: String, CodingKey {
        case id, name, config
        case agentDescription = "description"
    }
}

/// Legacy ConnectionConfig structure (for migration)
struct ConnectionConfig: Codable {
    let url: String
    let version: String
    let authToken: String?
    let clientId: String?
    let clientSecret: String?
    let certificateFingerprint: String?
}

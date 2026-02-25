//  CoreDataStack.swift
//

import Foundation
import CoreData

/// Manages CoreData persistent container and contexts
class CoreDataStack {
    static let shared = CoreDataStack()

    /// Main persistent container
    var persistentContainer: NSPersistentContainer

    init() {
        let container = NSPersistentContainer(name: "Aptove")
        // Enable lightweight migration for schema changes
        let storeOptions: [AnyHashable: Any] = [
            NSMigratePersistentStoresAutomaticallyOption: true,
            NSInferMappingModelAutomaticallyOption: true
        ]
        if let description = container.persistentStoreDescriptions.first {
            description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
            description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        }
        _ = storeOptions
        container.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                print("❌ CoreData: Failed to load persistent store: \(error), \(error.userInfo)")
                fatalError("Unresolved error \(error), \(error.userInfo)")
            } else {
                print("✅ CoreData: Persistent store loaded successfully")
                print("📍 CoreData: Store location: \(storeDescription.url?.path ?? "unknown")")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        self.persistentContainer = container
    }

    /// Designated initializer for testing with a custom container
    init(container: NSPersistentContainer) {
        self.persistentContainer = container
    }

    /// Main context for UI operations (runs on main thread)
    var viewContext: NSManagedObjectContext {
        return persistentContainer.viewContext
    }

    /// Creates a new background context for heavy operations
    func newBackgroundContext() -> NSManagedObjectContext {
        let context = persistentContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }

    /// Save changes in the view context
    func saveContext() {
        let context = viewContext
        if context.hasChanges {
            do {
                try context.save()
                print("✅ CoreData: Changes saved successfully")
            } catch {
                let nsError = error as NSError
                print("❌ CoreData: Failed to save context: \(nsError), \(nsError.userInfo)")
                fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
            }
        }
    }

    /// Save changes in a background context
    func saveBackgroundContext(_ context: NSManagedObjectContext) throws {
        guard context.hasChanges else { return }

        var saveError: Error?
        context.performAndWait {
            do {
                try context.save()
                print("✅ CoreData: Background context saved successfully")
            } catch {
                saveError = error
                print("❌ CoreData: Failed to save background context: \(error)")
            }
        }

        if let error = saveError {
            throw error
        }
    }

    /// Delete all data from CoreData (useful for testing/reset)
    func deleteAllData() throws {
        let entities = persistentContainer.managedObjectModel.entities

        for entity in entities {
            guard let entityName = entity.name else { continue }

            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)

            try viewContext.execute(deleteRequest)
        }

        try viewContext.save()
        print("✅ CoreData: All data deleted")
    }

    /// Create an in-memory stack for use in tests
    static func makeInMemory() -> CoreDataStack {
        let container = NSPersistentContainer(name: "Aptove")
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error = error {
                fatalError("Failed to load in-memory store: \(error)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return CoreDataStack(container: container)
    }
}

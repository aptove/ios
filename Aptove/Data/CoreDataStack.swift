//  CoreDataStack.swift
//

import Foundation
import CoreData

/// Manages CoreData persistent container and contexts
class CoreDataStack {
    static let shared = CoreDataStack()

    /// Main persistent container
    lazy var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "Aptove")

        container.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                // Log error for debugging
                print("❌ CoreData: Failed to load persistent store: \(error), \(error.userInfo)")

                // In production, you might want to handle this more gracefully
                // For development, we'll crash to catch issues early
                fatalError("Unresolved error \(error), \(error.userInfo)")
            } else {
                print("✅ CoreData: Persistent store loaded successfully")
                print("📍 CoreData: Store location: \(storeDescription.url?.path ?? "unknown")")
            }
        }

        // Enable automatic merging of changes
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        return container
    }()

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
                // In production, handle this error appropriately
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

    private init() {
        // Singleton - prevent external initialization
    }
}

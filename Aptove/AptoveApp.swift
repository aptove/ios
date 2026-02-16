import SwiftUI
import UserNotifications

/// AppDelegate for handling push notification registration
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            PushNotificationManager.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
        }
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            PushNotificationManager.shared.didFailToRegisterForRemoteNotifications(error: error)
        }
    }
    
    // Show notifications even when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .badge, .sound])
    }
}

@main
struct AptoveApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var agentManager: AgentManager
    @StateObject private var pushManager = PushNotificationManager.shared

    init() {
        print("🚀 AptoveApp: Application starting...")

        // Run migration from UserDefaults to CoreData if needed
        let repository = AgentRepository()
        let migrator = UserDefaultsMigrator(repository: repository)

        if migrator.needsMigration() {
            print("🔄 AptoveApp: Migration needed, starting...")
            do {
                try migrator.migrate()
                print("✅ AptoveApp: Migration completed successfully")
            } catch {
                print("❌ AptoveApp: Migration failed: \(error)")
            }
        } else {
            print("✅ AptoveApp: No migration needed")
        }

        // Initialize AgentManager with the repository
        _agentManager = StateObject(wrappedValue: AgentManager(repository: repository))

        print("🚀 AptoveApp: Main app initialized")
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(agentManager)
                .environmentObject(pushManager)
                .onAppear {
                    print("🚀 AptoveApp: ContentView appeared - app fully launched")
                    // Request push notification permissions on launch
                    pushManager.requestAuthorization()
                }
        }
    }
}

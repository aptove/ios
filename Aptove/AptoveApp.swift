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
    @AppStorage("isDarkMode") private var isDarkMode: Bool = true
    @AppStorage("appLanguage") private var appLanguage: String = ""
    @State private var showSplash = true
    @Environment(\.scenePhase) private var scenePhase

    init() {
        print("🚀 AptoveApp: Application starting...")

        // Set up CoreData repository
        let repository = AgentRepository()

        // Run one-time migration from UserDefaults to CoreData
        let migrator = UserDefaultsMigrator(repository: repository)
        if migrator.needsMigration() {
            do {
                try migrator.migrate()
            } catch {
                print("⚠️ AptoveApp: Migration failed (non-fatal): \(error.localizedDescription)")
            }
        }

        _agentManager = StateObject(wrappedValue: AgentManager(repository: repository))
        print("🚀 AptoveApp: Main app initialized")
    }
    
    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(agentManager)
                    .environmentObject(pushManager)
                    .preferredColorScheme(isDarkMode ? .dark : .light)
                    .environment(\.locale, appLanguage.isEmpty ? .autoupdatingCurrent : Locale(identifier: appLanguage))
                    .onAppear {
                        print("🚀 AptoveApp: ContentView appeared - app fully launched")
                        // Request push notification permissions on launch
                        pushManager.requestAuthorization()
                    }
                    .onChange(of: scenePhase) { _, newPhase in
                        switch newPhase {
                        case .active:
                            print("🌅 [push-dbg] App became ACTIVE — reconnecting agents")
                            agentManager.autoConnectAllAgents()
                        case .inactive:
                            print("🌄 [push-dbg] App became INACTIVE (transitioning)")
                        case .background:
                            print("🌙 [push-dbg] App entered BACKGROUND — closing WebSocket so bridge detects disconnect and pushes")
                            Task {
                                await agentManager.disconnectAll()
                            }
                        @unknown default:
                            break
                        }
                    }

                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation(.easeOut(duration: 0.4)) {
                                    showSplash = false
                                }
                            }
                        }
                }
            }
        }
    }
}

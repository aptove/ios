import SwiftUI
import UserNotifications
import UIKit

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

    // Handle notification tap — extract agent name for deep-link navigation
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        print("🔔 [push-dbg] Notification tapped, userInfo: \(userInfo)")

        if let data = userInfo["data"] as? [String: Any],
           let agentName = data["agentName"] as? String {
            print("🔔 [push-dbg] Extracted agentName from push: \(agentName)")
            Task { @MainActor in
                PushNotificationManager.shared.tappedAgentName = agentName
            }
        }
        completionHandler()
    }
}

@main
struct AptoveApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("isDarkMode") private var isDarkMode: Bool = true
    @AppStorage("appLanguage") private var appLanguage: String = ""
    @State private var showSplash = true

    // Plain let — not @StateObject — so publishes from agentManager don't re-evaluate App.body.
    private let agentManager: AgentManager

    init() {
        print("🚀 AptoveApp: Application starting...")

        let repository = AgentRepository()

        let migrator = UserDefaultsMigrator(repository: repository)
        if migrator.needsMigration() {
            do {
                try migrator.migrate()
            } catch {
                print("⚠️ AptoveApp: Migration failed (non-fatal): \(error.localizedDescription)")
            }
        }

        agentManager = AgentManager(repository: repository)
        print("🚀 AptoveApp: Main app initialized")
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(agentManager)
                    .environmentObject(PushNotificationManager.shared)
                    .preferredColorScheme(isDarkMode ? .dark : .light)
                    .environment(\.locale, appLanguage.isEmpty ? .autoupdatingCurrent : Locale(identifier: appLanguage))
                    .onAppear {
                        print("🚀 AptoveApp: ContentView appeared - app fully launched")
                        PushNotificationManager.shared.requestAuthorization()
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

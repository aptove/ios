import SwiftUI
import UserNotifications
import UIKit
import os

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

    // Called whenever the app is running (foreground or background) and a push with
    // content-available: 1 arrives. Used to increment the unread badge without user tap.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        if let data = userInfo["data"] as? [String: Any],
           let agentName = data["agentName"] as? String {
            Task { @MainActor in
                PushNotificationManager.shared.backgroundPushAgentName = agentName
            }
        }
        completionHandler(.newData)
    }

    // Handle notification tap — extract agent name for deep-link navigation
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        Logger.push.debug("Notification tapped, userInfo: \(userInfo)")

        if let data = userInfo["data"] as? [String: Any],
           let agentName = data["agentName"] as? String {
            Logger.push.debug("Extracted agentName from push: \(agentName)")
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
    @AppStorage("isBiometricLockEnabled") private var isBiometricLockEnabled = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSplash = true
    @State private var isLocked = false

    // Plain let — not @StateObject — so publishes from agentManager don't re-evaluate App.body.
    private let agentManager: AgentManager

    init() {
        Logger.app.debug("Application starting...")

        let repository = AgentRepository()

        let migrator = UserDefaultsMigrator(repository: repository)
        if migrator.needsMigration() {
            do {
                try migrator.migrate()
            } catch {
                Logger.app.error("Migration failed (non-fatal): \(error.localizedDescription)")
            }
        }

        agentManager = AgentManager(repository: repository)
        Logger.app.debug("Main app initialized")
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
                        Logger.app.debug("ContentView appeared — app fully launched")
                        PushNotificationManager.shared.requestAuthorization()
                    }

                // Lock screen sits above ContentView but below the splash so there is
                // never a flash of content between the splash fading and auth appearing.
                if isLocked {
                    BiometricLockView { isLocked = false }
                        .ignoresSafeArea()
                }

                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                // Set lock BEFORE the fade starts so the lock screen is
                                // already in place when the splash disappears.
                                if isBiometricLockEnabled { isLocked = true }
                                withAnimation(.easeOut(duration: 0.4)) {
                                    showSplash = false
                                }
                                // Notify BiometricLockView to start auth once splash is gone.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                    NotificationCenter.default.post(name: .aptoveSplashComplete, object: nil)
                                }
                            }
                        }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background && isBiometricLockEnabled { isLocked = true }
            }
        }
    }
}

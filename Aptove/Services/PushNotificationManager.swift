import Foundation
import UserNotifications
import UIKit

/// Manages push notification registration and token delivery.
/// Handles requesting permission, storing the device token, and
/// providing it to ACPClientWrapper for relay registration.
@MainActor
class PushNotificationManager: NSObject, ObservableObject {
    static let shared = PushNotificationManager()
    
    /// The current APNs device token (hex-encoded)
    @Published private(set) var deviceToken: String?

    /// Whether push notifications are authorized
    @Published private(set) var isAuthorized: Bool = false

    /// Agent name extracted from the tapped push notification — consumed by ContentView for navigation.
    @Published var tappedAgentName: String?
    
    /// Callbacks waiting for a device token
    private var tokenCallbacks: [(String) -> Void] = []
    
    private override init() {
        super.init()
        print("📲 PushNotificationManager: Initialized")
    }
    
    /// Request push notification permissions and register for remote notifications
    func requestAuthorization() {
        print("📲 PushNotificationManager: Requesting notification authorization...")
        
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("❌ PushNotificationManager: Authorization error: \(error.localizedDescription)")
                    return
                }
                
                print("📲 PushNotificationManager: Authorization \(granted ? "granted" : "denied")")
                self?.isAuthorized = granted
                
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
    }
    
    /// Called by AppDelegate when APNs returns a device token
    func didRegisterForRemoteNotifications(deviceToken data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        print("📲 PushNotificationManager: Received APNs token: \(token.prefix(16))...")
        
        #if DEBUG
        print("🔐 BRUNO TOKEN - iOS APNs: \(token)")
        #endif
        
        self.deviceToken = token
        
        // Notify any waiting callbacks
        for callback in tokenCallbacks {
            callback(token)
        }
        tokenCallbacks.removeAll()
    }
    
    /// Called by AppDelegate when APNs registration fails
    func didFailToRegisterForRemoteNotifications(error: Error) {
        print("❌ PushNotificationManager: Failed to register for remote notifications: \(error.localizedDescription)")
    }
    
    /// Get the current device token, or wait for one to arrive
    func getDeviceToken() async -> String? {
        // If we already have a token, return it
        if let token = deviceToken {
            return token
        }
        
        // Wait for a token (with timeout)
        return await withCheckedContinuation { continuation in
            // Check again in case it arrived between the check and here
            if let token = deviceToken {
                continuation.resume(returning: token)
                return
            }
            
            // Set up a callback that will be called when token arrives
            var resumed = false
            tokenCallbacks.append { token in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: token)
            }
            
            // Timeout after 10 seconds
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if !resumed {
                    resumed = true
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    /// Get the bundle identifier for push registration
    var bundleId: String {
        Bundle.main.bundleIdentifier ?? "com.aptove.app"
    }
}

import SwiftUI

@main
struct AptoveApp: App {
    @StateObject private var agentManager = AgentManager()
    
    init() {
        print("🚀 AptoveApp: Application starting...")
        print("🚀 AptoveApp: Main app initialized")
    }
    
    var body: some Scene {
        print("🚀 AptoveApp: body computed, creating WindowGroup")
        return WindowGroup {
            ContentView()
                .environmentObject(agentManager)
                .onAppear {
                    print("🚀 AptoveApp: ContentView appeared - app fully launched")
                }
        }
    }
}

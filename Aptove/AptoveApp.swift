import SwiftUI

@main
struct AptoveApp: App {
    @StateObject private var agentManager = AgentManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(agentManager)
        }
    }
}

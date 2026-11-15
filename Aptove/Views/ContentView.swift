import SwiftUI
import UIKit
import os

enum BottomTab: Hashable { case chat, starred, tasks, settings }

// MARK: - Tab bar height (kept for sub-views that add bottom padding)

private struct TabBarHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var tabBarHeight: CGFloat {
        get { self[TabBarHeightKey.self] }
        set { self[TabBarHeightKey.self] = newValue }
    }
}

// MARK: -

extension Bundle {
    /// Loads a localized string from the `.lproj` bundle for `language`, bypassing the
    /// UIKit navigation bar's inability to respect SwiftUI's `\.locale` environment.
    static func localized(_ key: String, language: String) -> String {
        let lang = language.isEmpty ? "en" : language
        guard let path = main.path(forResource: lang, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

struct ChatDestination: Hashable {
    let agentId: String
    let scrollToMessageId: String?
    var returnsToStarred: Bool = false
}

struct ContentView: View {
    @EnvironmentObject private var agentManager: AgentManager
    @EnvironmentObject private var pushManager: PushNotificationManager
    @AppStorage("appLanguage") private var appLanguage: String = ""
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: BottomTab = .chat
    @State private var isInChat = false
    @State private var showingQRScanner = false
    @State private var hasGoneToBackground = false
    @State private var searchText = ""
    @State private var isSearchActive = false
    @State private var activeChatDestination: ChatDestination?

    init() {
        Logger.app.debug("ContentView initializing...")
    }

    private var isChatOpen: Bool { activeChatDestination != nil }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    Group {
                        if agentManager.agents.isEmpty {
                            EmptyStateView()
                        } else {
                            AgentListView(
                                isInChat: $isInChat,
                                searchText: searchText,
                                isSearchActive: $isSearchActive,
                                activeChatDestination: $activeChatDestination
                            )
                        }
                    }
                    .navigationTitle(Bundle.localized("Agents", language: appLanguage))
                    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("search_conversations_prompt"))
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                showingQRScanner = true
                            } label: {
                                Image(systemName: "plus")
                            }
                        }
                    }
                    .sheet(isPresented: $showingQRScanner) {
                        QRScannerView(isPresented: $showingQRScanner)
                    }
                }
                .toolbar(isSearchActive ? .hidden : .visible, for: .tabBar)
                .tabItem {
                    Label(Bundle.localized("Chat", language: appLanguage), systemImage: "bubble.left.and.bubble.right.fill")
                }
                .tag(BottomTab.chat)

                StarredMessagesView(selectedTab: $selectedTab, activeChatDestination: $activeChatDestination)
                    .tabItem {
                        Label(Bundle.localized("Starred", language: appLanguage), systemImage: "star.fill")
                    }
                    .tag(BottomTab.starred)

                TasksListView(selectedTab: $selectedTab)
                    .tabItem {
                        Label(Bundle.localized("Tasks", language: appLanguage), systemImage: "clock.fill")
                    }
                    .tag(BottomTab.tasks)

                SettingsView()
                    .tabItem {
                        Label(Bundle.localized("Settings", language: appLanguage), systemImage: "gearshape.fill")
                    }
                    .tag(BottomTab.settings)
            }

            // Full-screen chat overlay — sits above the TabView, completely hides tab bar
            if let dest = activeChatDestination {
                NavigationStack {
                    ChatView(
                        agentId: dest.agentId,
                        scrollToMessageId: dest.scrollToMessageId,
                        isInChat: $isInChat,
                        onDismiss: {
                            activeChatDestination = nil
                            if dest.returnsToStarred {
                                selectedTab = .starred
                            }
                        }
                    )
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationBarBackButtonHidden(true)
                }
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isChatOpen)
        .onAppear {
            Logger.app.debug("ContentView: View appeared and rendered")
        }
        .onChange(of: activeChatDestination) { _, dest in
            if dest == nil {
                agentManager.activeChatAgentId = nil
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                if activeChatDestination != nil {
                    isInChat = true
                }
                guard hasGoneToBackground else {
                    Logger.push.debug("App became ACTIVE (initial launch — skipping reconnect)")
                    break
                }
                Logger.push.debug("App became ACTIVE — reconnecting agents (0.5s delay for in-flight disconnect)")
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    agentManager.autoConnectAllAgents()
                    agentManager.recheckAuthStatusForAllAgents()
                }
            case .inactive:
                Logger.push.debug("App became INACTIVE (transitioning)")
            case .background:
                hasGoneToBackground = true
                Logger.push.debug("App entered BACKGROUND — closing WebSocket so bridge detects disconnect and pushes")
                final class BGTaskBox: @unchecked Sendable { var id = UIBackgroundTaskIdentifier.invalid }
                let bgTask = BGTaskBox()
                bgTask.id = UIApplication.shared.beginBackgroundTask(withName: "ws-background-disconnect") {
                    UIApplication.shared.endBackgroundTask(bgTask.id)
                }
                Task {
                    await agentManager.disconnectAll()
                    UIApplication.shared.endBackgroundTask(bgTask.id)
                }
            @unknown default:
                break
            }
        }
        .onChange(of: pushManager.backgroundPushAgentName) { _, agentName in
            guard let agentName else { return }
            Task { @MainActor in pushManager.backgroundPushAgentName = nil }
            guard let agent = agentManager.agents.first(where: { $0.name == agentName }) else { return }
            Task {
                _ = await agentManager.connectAgent(agentId: agent.id)
            }
        }
        .onChange(of: pushManager.tappedAgentName) { _, agentName in
            guard let agentName else { return }
            Task { @MainActor in pushManager.tappedAgentName = nil }
            Logger.push.debug("Navigating to agent: \(agentName)")

            guard let agent = agentManager.agents.first(where: { $0.name == agentName }) else {
                Logger.push.debug("No agent found with name '\(agentName)'")
                return
            }

            selectedTab = .chat
            activeChatDestination = ChatDestination(agentId: agent.id, scrollToMessageId: nil)
        }
        .onChange(of: agentManager.forwardNavigationRequest) { _, agentId in
            guard let agentId else { return }
            Task { @MainActor in agentManager.forwardNavigationRequest = nil }
            selectedTab = .chat
            activeChatDestination = ChatDestination(agentId: agentId, scrollToMessageId: nil)
        }
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 64))
                .foregroundColor(.gray)

            Text("No Agents Connected")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Tap the + button to scan a QR code\nand connect to an agent")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
        .environmentObject(AgentManager())
}

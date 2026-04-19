import SwiftUI

enum BottomTab { case chat, settings }

struct ContentView: View {
    @EnvironmentObject private var agentManager: AgentManager
    @State private var selectedTab: BottomTab = .chat
    @State private var isInChat = false
    @State private var showingQRScanner = false

    init() {
        print("🖥️  ContentView: Initializing...")
    }

    var body: some View {
        ZStack {
            // Chat tab — always rendered so NavigationStack state is preserved
            NavigationStack {
                Group {
                    if agentManager.agents.isEmpty {
                        EmptyStateView()
                    } else {
                        AgentListView(isInChat: $isInChat)
                    }
                }
                .navigationTitle("Agents")
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
            .opacity(selectedTab == .chat ? 1 : 0)
            .allowsHitTesting(selectedTab == .chat)

            // Settings tab — full screen, not a sheet
            SettingsView()
                .opacity(selectedTab == .settings ? 1 : 0)
                .allowsHitTesting(selectedTab == .settings)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isInChat {
                BottomTabBar(selectedTab: $selectedTab)
                    .padding(.bottom, 8)
            }
        }
        .onAppear {
            print("🖥️  ContentView: View appeared and rendered")
        }
    }
}

private struct BottomTabBar: View {
    @Binding var selectedTab: BottomTab

    var body: some View {
        HStack(spacing: 0) {
            TabBarButton(icon: "bubble.left.and.bubble.right.fill", label: "Chat", selected: selectedTab == .chat) {
                selectedTab = .chat
            }
            TabBarButton(icon: "gearshape.fill", label: "Settings", selected: selectedTab == .settings) {
                selectedTab = .settings
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(.bar)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        )
        .padding(.horizontal, 24)
    }
}

private struct TabBarButton: View {
    let icon: String
    let label: LocalizedStringKey
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                Text(label)
                    .font(.caption2)
                    .fontWeight(.medium)
            }
            .foregroundColor(selected ? .blue : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(selected ? Color.blue.opacity(0.12) : Color.clear)
            )
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

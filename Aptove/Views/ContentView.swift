import SwiftUI

struct HideBottomBarKey: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

struct ContentView: View {
    // Receive the single AgentManager created in AptoveApp — do NOT create a second instance here.
    @EnvironmentObject private var agentManager: AgentManager
    @State private var showingQRScanner = false
    @State private var showingSettings = false
    @State private var showBottomBar = true

    init() {
        print("🖥️  ContentView: Initializing...")
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationStack {
                Group {
                    if agentManager.agents.isEmpty {
                        EmptyStateView()
                    } else {
                        AgentListView()
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
            .onPreferenceChange(HideBottomBarKey.self) { hide in
                withAnimation(.easeInOut(duration: 0.2)) {
                    showBottomBar = !hide
                }
            }

            if showBottomBar {
                CarouselBar(onSettings: { showingSettings = true })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onAppear {
            print("🖥️  ContentView: View appeared and rendered")
        }
    }
}

private struct CarouselBar: View {
    let onSettings: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: onSettings) {
                VStack(spacing: 4) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 22))
                    Text("Settings")
                        .font(.caption2)
                }
                .foregroundColor(.white)
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemGray2).opacity(0.85))
                .ignoresSafeArea(edges: .bottom)
        )
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

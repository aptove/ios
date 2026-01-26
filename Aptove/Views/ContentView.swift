import SwiftUI

struct ContentView: View {
    @StateObject private var agentManager = AgentManager()
    @State private var showingQRScanner = false
    
    init() {
        print("🖥️  ContentView: Initializing...")
    }
    
    var body: some View {
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
        .environmentObject(agentManager)
        .onAppear {
            print("🖥️  ContentView: View appeared and rendered")
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
}

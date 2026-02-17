import SwiftUI

struct AgentConfigurationView: View {
    @EnvironmentObject var agentManager: AgentManager
    @StateObject private var viewModel: AgentConfigurationViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var showClearSessionAlert = false
    @State private var showDeleteAgentAlert = false
    
    init(agentId: String) {
        _viewModel = StateObject(wrappedValue: AgentConfigurationViewModel(agentId: agentId))
    }
    
    var body: some View {
        List {
            if let agent = viewModel.agent {
                // Agent Information Section
                Section("Agent Information") {
                    LabeledContent("Name", value: agent.name)
                    LabeledContent("URL", value: agent.url)
                    LabeledContent("Status") {
                        HStack {
                            Circle()
                                .fill(statusColor(for: agent.status))
                                .frame(width: 8, height: 8)
                            Text(statusText(for: agent.status))
                        }
                    }
                }
                
                // Session Information Section
                Section("Session Information") {
                    if let sessionId = agent.activeSessionId {
                        LabeledContent("Session ID") {
                            Text(String(sessionId.prefix(16)) + "...")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        
                        if let startedAt = agent.sessionStartedAt {
                            LabeledContent("Started", value: formatDate(startedAt))
                        }
                        
                        LabeledContent("Messages", value: "\(viewModel.messageCount)")
                        
                        LabeledContent("Supports Resume", value: agent.supportsLoadSession ? "Yes" : "No")
                    } else {
                        Text("No active session")
                            .foregroundColor(.secondary)
                    }
                }
                
                // Actions Section
                Section("Actions") {
                    // Clear Session Button
                    Button(role: .destructive) {
                        showClearSessionAlert = true
                    } label: {
                        HStack {
                            if viewModel.isClearingSession {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            Text("Clear Session")
                        }
                    }
                    .disabled(viewModel.isClearingSession || agent.activeSessionId == nil)
                    
                    // Delete Agent Button
                    Button(role: .destructive) {
                        showDeleteAgentAlert = true
                    } label: {
                        HStack {
                            if viewModel.isDeletingAgent {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "trash")
                            }
                            Text("Delete Agent")
                        }
                    }
                    .disabled(viewModel.isDeletingAgent)
                }
                
                // Help Section
                Section {
                    Text("Clear Session will delete all conversation history and start a fresh session.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    
                    Text("Delete Agent will permanently remove this agent and all associated data.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else {
                Section {
                    Text("Agent not found")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Configuration")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.setAgentManager(agentManager)
        }
        .onChange(of: viewModel.shouldDismiss) { _, shouldDismiss in
            if shouldDismiss {
                dismiss()
            }
        }
        .alert("Clear Session?", isPresented: $showClearSessionAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                viewModel.clearSession()
            }
        } message: {
            Text("This will delete all conversation history and start a fresh session. This cannot be undone.")
        }
        .alert("Delete Agent?", isPresented: $showDeleteAgentAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                viewModel.deleteAgent()
            }
        } message: {
            if let agent = viewModel.agent {
                Text("Are you sure you want to delete \"\(agent.name)\"? This will remove all conversation history.")
            } else {
                Text("Are you sure you want to delete this agent?")
            }
        }
        .alert("Error", isPresented: .init(
            get: { viewModel.error != nil },
            set: { if !$0 { viewModel.clearError() } }
        )) {
            Button("OK") {
                viewModel.clearError()
            }
        } message: {
            if let error = viewModel.error {
                Text(error)
            }
        }
    }
    
    private func statusColor(for status: ConnectionStatus) -> Color {
        switch status {
        case .connected:
            return .green
        case .disconnected:
            return .gray
        case .reconnecting:
            return .orange
        }
    }
    
    private func statusText(for status: ConnectionStatus) -> String {
        switch status {
        case .connected:
            return "Connected"
        case .disconnected:
            return "Disconnected"
        case .reconnecting:
            return "Reconnecting"
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

#Preview {
    NavigationStack {
        AgentConfigurationView(agentId: "test-agent")
            .environmentObject(AgentManager())
    }
}

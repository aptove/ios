import SwiftUI
import PhotosUI

struct AgentConfigurationView: View {
    @EnvironmentObject var agentManager: AgentManager
    @StateObject private var viewModel: AgentConfigurationViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var appLanguage: String = ""

    let agentId: String

    @Environment(\.tabBarHeight) private var tabBarHeight
    @State private var showClearSessionAlert = false
    @State private var showDeleteAgentAlert = false
    @State private var avatarImage: UIImage?
    @State private var showAvatarPicker = false
    @State private var avatarPickerItem: PhotosPickerItem?

    init(agentId: String) {
        self.agentId = agentId
        _viewModel = StateObject(wrappedValue: AgentConfigurationViewModel(agentId: agentId))
    }

    var body: some View {
        List {
            if let agent = viewModel.agent {
                // Avatar Section
                Section {
                    avatarRow(agent: agent)
                }

                // Agent Information Section
                Section("Agent Information") {
                    HStack {
                        Text("Name")
                        Spacer()
                        TextField("Agent Name", text: $viewModel.editableName)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { viewModel.saveNameIfChanged() }
                    }
                    LabeledContent("Status") {
                        HStack {
                            Circle()
                                .fill(statusColor(for: agent.status))
                                .frame(width: 8, height: 8)
                            switch agent.status {
                            case .connected:    Text("Connected")
                            case .disconnected: Text("Disconnected")
                            case .reconnecting: Text("Reconnecting")
                            }
                        }
                    }
                }

                // Transports Section
                if !viewModel.endpoints.isEmpty {
                    Section("Transports") {
                        ForEach(viewModel.endpoints) { endpoint in
                            TransportEndpointRow(endpoint: endpoint)
                        }
                        .onDelete { indexSet in
                            indexSet.forEach { i in
                                viewModel.deleteEndpoint(id: viewModel.endpoints[i].id)
                            }
                        }
                    }
                }

                // Protocol Version Section
                Section {
                    Picker("ACP Version", selection: $viewModel.acpVersionMode) {
                        ForEach(ACPVersionMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: viewModel.acpVersionMode) { _, newMode in
                        viewModel.saveVersionMode(newMode)
                    }
                    Text(viewModel.acpVersionMode.description)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } header: {
                    Text("ACP Version")
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
                            LabeledContent("Started") {
                                Text(startedAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                            }
                        }

                        LabeledContent("Messages", value: "\(viewModel.messageCount)")
                        LabeledContent("Supports Resume") {
                            Text(agent.supportsLoadSession ? "Yes" : "No")
                        }
                    } else {
                        Text("No active session")
                            .foregroundColor(.secondary)
                    }
                }

                // Actions Section
                Section("Actions") {
                    Button(role: .destructive) {
                        showClearSessionAlert = true
                    } label: {
                        HStack {
                            if viewModel.isClearingSession {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            Text("Clear Session")
                        }
                    }
                    .disabled(viewModel.isClearingSession || agent.activeSessionId == nil)

                    Button(role: .destructive) {
                        showDeleteAgentAlert = true
                    } label: {
                        HStack {
                            if viewModel.isDeletingAgent {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Image(systemName: "trash")
                            }
                            Text("Delete Agent")
                        }
                    }
                    .disabled(viewModel.isDeletingAgent)
                }

                Section {
                    Text("Clear Session will delete all conversation history and start a fresh session.")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Text("Delete Agent will permanently remove this agent and all associated data.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Color.clear
                    .frame(height: tabBarHeight)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            } else {
                Section {
                    Text("Agent not found")
                        .foregroundColor(.secondary)
                }
            }
        }
        .onDisappear { viewModel.saveNameIfChanged() }
        .navigationTitle(Bundle.localized("Configuration", language: appLanguage))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.setAgentManager(agentManager)
            avatarImage = AvatarStore.load(for: agentId)
        }
        .photosPicker(isPresented: $showAvatarPicker, selection: $avatarPickerItem, matching: .images)
        .onChange(of: avatarPickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    AvatarStore.save(image, for: agentId)
                    avatarImage = image
                }
                avatarPickerItem = nil
            }
        }
        .onChange(of: viewModel.shouldDismiss) { _, shouldDismiss in
            if shouldDismiss { dismiss() }
        }
        .alert("Clear Session?", isPresented: $showClearSessionAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) { viewModel.clearSession() }
        } message: {
            Text("This will delete all conversation history and start a fresh session. This cannot be undone.")
        }
        .alert("Delete Agent?", isPresented: $showDeleteAgentAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) { viewModel.deleteAgent() }
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
            Button("OK") { viewModel.clearError() }
        } message: {
            if let error = viewModel.error { Text(error) }
        }
    }

    @ViewBuilder
    private func avatarRow(agent: Agent) -> some View {
        let color = statusColor(for: agent.status)
        let initial = String(agent.name.prefix(1).uppercased())
        HStack {
            Spacer()
            Button { showAvatarPicker = true } label: {
                avatarBadge(color: color, initial: initial)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 20, leading: 0, bottom: 12, trailing: 0))
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func avatarBadge(color: Color, initial: String) -> some View {
        ZStack(alignment: .bottomTrailing) {
            avatarCircle(color: color, initial: initial, size: 72)
            Image(systemName: "pencil.circle.fill")
                .font(.title2)
                .foregroundColor(.accentColor)
                .background(Circle().fill(Color(.systemBackground)).padding(2))
        }
    }

    @ViewBuilder
    private func avatarCircle(color: Color, initial: String, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(color)
            if let img = avatarImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .frame(width: size, height: size)
    }

    private func statusColor(for status: ConnectionStatus) -> Color {
        switch status {
        case .connected:    return .green
        case .disconnected: return .gray
        case .reconnecting: return .orange
        }
    }

}

// MARK: - Transport Endpoint Row

private struct TransportEndpointRow: View {
    let endpoint: TransportEndpointInfo

    var body: some View {
        HStack(spacing: 12) {
            // Active indicator — green when this transport is currently connected
            Circle()
                .fill(endpoint.isActive ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(transportDisplayName(endpoint.transport))
                    .font(.body)
                Text(endpoint.url)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func transportDisplayName(_ transport: String) -> String {
        switch transport {
        case "local":           return "Local"
        case "tailscale-serve": return "Tailscale"
        default:
            return FeatureRegistry.shared.provider(forTransport: transport)?.displayName ?? transport.capitalized
        }
    }
}

#Preview {
    NavigationStack {
        AgentConfigurationView(agentId: "test-agent")
            .environmentObject(AgentManager())
    }
}

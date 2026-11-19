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
    @State private var showAvatarOptions = false
    @FocusState private var isNameFocused: Bool

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
                            .focused($isNameFocused)
                            .onSubmit { viewModel.saveNameIfChanged() }
                    }
                }

                // Connection Status Section — shows transport and AI agent states separately
                Section("connection_status_section") {
                    // Transport row — when agentCommandError is set, the transport was
                    // reachable (bridge/agentError arrived over the connection) even though
                    // the WebSocket is now closed. Show green "Connected" in that case.
                    LabeledContent("connection_transport") {
                        VStack(alignment: .trailing, spacing: 2) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(agent.agentCommandError != nil ? Color.green : statusColor(for: agent.status))
                                    .frame(width: 8, height: 8)
                                Text(transportStatusText(agent: agent))
                            }
                            if let url = activeConnectionURL(agent: agent) {
                                Text(url)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    // AI Agent row
                    LabeledContent("connection_ai_agent") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(aiStatusColor(agent: agent))
                                .frame(width: 8, height: 8)
                            Text(aiStatusText(agent: agent))
                        }
                    }

                    // Error detail — shown when AI process failed to start
                    if let error = agent.agentCommandError {
                        Text(error)
                            .font(.footnote)
                            .foregroundColor(.secondary)
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

                // Actions Section
                Section("Actions") {
                    Button(role: .destructive) {
                        showClearSessionAlert = true
                    } label: {
                        HStack(alignment: .top) {
                            if viewModel.isClearingSession {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Clear Session")
                                Text("Clear Session will delete all conversation history and start a fresh session.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .disabled(viewModel.isClearingSession || agent.activeSessionId == nil)

                    Button(role: .destructive) {
                        showDeleteAgentAlert = true
                    } label: {
                        HStack(alignment: .top) {
                            if viewModel.isDeletingAgent {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Image(systemName: "trash")
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Delete Agent")
                                Text("Delete Agent will permanently remove this agent and all associated data.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .disabled(viewModel.isDeletingAgent)
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
        .simultaneousGesture(TapGesture().onEnded { isNameFocused = false })
        .onDisappear { viewModel.saveNameIfChanged() }
        .navigationTitle(Bundle.localized("Configuration", language: appLanguage))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.setAgentManager(agentManager)
            avatarImage = AvatarStore.load(for: agentId)
        }
        .photosPicker(isPresented: $showAvatarPicker, selection: $avatarPickerItem, matching: .images)
        .confirmationDialog("", isPresented: $showAvatarOptions, titleVisibility: .hidden) {
            Button("avatar_change_photo") { showAvatarPicker = true }
            Button("avatar_remove_photo", role: .destructive) {
                AvatarStore.delete(for: agentId)
                avatarImage = nil
            }
            Button("Cancel", role: .cancel) { }
        }
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
        let color: Color = (agent.isAuthenticated == false || agent.agentCommandError != nil)
            ? .orange
            : statusColor(for: agent.status)
        HStack {
            Spacer()
            Button {
                if avatarImage != nil {
                    showAvatarOptions = true
                } else {
                    showAvatarPicker = true
                }
            } label: {
                avatarBadge(color: color, name: agent.name)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 20, leading: 0, bottom: 12, trailing: 0))
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func avatarBadge(color: Color, name: String) -> some View {
        ZStack(alignment: .bottomTrailing) {
            avatarCircle(color: color, name: name, size: 72)
            Image(systemName: "pencil.circle.fill")
                .font(.title2)
                .foregroundColor(.accentColor)
                .background(Circle().fill(Color(.systemBackground)).padding(2))
        }
    }

    @ViewBuilder
    private func avatarCircle(color: Color, name: String, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(color)
            if let img = avatarImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                AgentIdenticon(name: name)
                    .frame(width: size, height: size)
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

    private func transportStatusText(agent: Agent) -> String {
        // When the AI process fails to spawn, the WebSocket closes immediately after
        // bridge/agentError is received — so agent.status is .disconnected by the time
        // the user opens this view. But the transport IS reachable; show "Connected".
        if agent.agentCommandError != nil {
            let transport = agentManager.activeTransport(for: agent.id)
                ?? agentManager.firstTransportName(for: agent.id)
                ?? "local"
            return connectedTransportText(transport)
        }
        switch agent.status {
        case .connected:
            let transport = agentManager.activeTransport(for: agent.id) ?? "local"
            return connectedTransportText(transport)
        case .reconnecting:
            return NSLocalizedString("connection_transport_reconnecting", comment: "")
        case .disconnected:
            return NSLocalizedString("connection_transport_disconnected", comment: "")
        }
    }

    private func connectedTransportText(_ transport: String) -> String {
        let name = transportShortName(transport)
        switch transport {
        case "local", "tailscale-serve", "tailscale-ip":
            return name
        default:
            return String(format: NSLocalizedString("connection_transport_connected", comment: ""), name)
        }
    }

    private func transportShortName(_ transport: String) -> String {
        switch transport {
        case "local":           return "Local"
        case "cloudflare":      return "Cloudflare"
        case "tailscale-serve", "tailscale-ip": return "Tailscale"
        default:                return transport
        }
    }

    private func activeConnectionURL(agent: Agent) -> String? {
        guard agent.status == .connected || agent.agentCommandError != nil else { return nil }
        return viewModel.endpoints.first(where: { $0.isActive })?.url
    }

    private func aiStatusColor(agent: Agent) -> Color {
        if agent.agentCommandError != nil { return .orange }
        if agent.status == .connected { return .green }
        return .gray
    }

    private func aiStatusText(agent: Agent) -> String {
        if agent.agentCommandError != nil {
            return NSLocalizedString("connection_ai_offline", comment: "")
        }
        if agent.status == .connected {
            return NSLocalizedString("connection_ai_running", comment: "")
        }
        return NSLocalizedString("connection_ai_unknown", comment: "")
    }

}

#Preview {
    NavigationStack {
        AgentConfigurationView(agentId: "test-agent")
            .environmentObject(AgentManager())
    }
}

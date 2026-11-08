import SwiftUI

// MARK: - Search result model

private struct ConversationSearchResult: Identifiable {
    let id: String          // message id
    let agentId: String
    let agentName: String
    let avatarImage: UIImage?
    let message: Message
}

// MARK: - AgentListView

struct AgentListView: View {
    @EnvironmentObject var agentManager: AgentManager
    @Binding var isInChat: Bool
    @State private var searchText = ""
    @State private var agentToDelete: Agent?
    @State private var showingDeleteConfirmation = false
    @State private var agentToConfigureId: String? = nil
    @State private var avatarImages: [String: UIImage] = [:]

    private var searchResults: [ConversationSearchResult] {
        guard !searchText.isEmpty else { return [] }
        let lower = searchText.lowercased()
        return agentManager.agents.flatMap { agent -> [ConversationSearchResult] in
            guard let conv = agentManager.conversations[agent.id] else { return [] }
            return conv.messages
                .filter { $0.type == .text && !$0.text.isEmpty && $0.text.lowercased().contains(lower) }
                .map { ConversationSearchResult(id: $0.id, agentId: agent.id, agentName: agent.name, avatarImage: avatarImages[agent.id], message: $0) }
        }
        .sorted { $0.message.timestamp > $1.message.timestamp }
    }

    var body: some View {
        List {
            if searchText.isEmpty {
                ForEach(agentManager.agents) { agent in
                    NavigationLink(value: agent.id) {
                        AgentRow(agent: agent, avatarImage: avatarImages[agent.id])
                    }
                    .contextMenu {
                        Button {
                            agentToConfigureId = agent.id
                        } label: {
                            Label("Configure", systemImage: "gear")
                        }
                        Button(role: .destructive) {
                            agentToDelete = agent
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            agentToDelete = agent
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            agentToConfigureId = agent.id
                        } label: {
                            Label("Configure", systemImage: "gear")
                        }
                        .tint(.blue)
                    }
                }
            } else {
                if searchResults.isEmpty {
                    Text("no_search_results")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(searchResults) { result in
                        NavigationLink(value: result.agentId) {
                            SearchResultRow(result: result)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("search_conversations_prompt"))
        .onAppear { loadAvatars() }
        .navigationDestination(isPresented: Binding(
            get: { agentToConfigureId != nil },
            set: { if !$0 { agentToConfigureId = nil } }
        )) {
            if let id = agentToConfigureId {
                AgentConfigurationView(agentId: id)
            }
        }
        .alert("Delete Agent?", isPresented: $showingDeleteConfirmation, presenting: agentToDelete) { agent in
            Button("Cancel", role: .cancel) {
                agentToDelete = nil
            }
            Button("Delete", role: .destructive) {
                Task {
                    await agentManager.removeAgent(agentId: agent.id)
                }
                agentToDelete = nil
            }
        } message: { agent in
            Text("Are you sure you want to delete \"\(agent.name)\"? This will remove all conversation history.")
        }
    }

    private func loadAvatars() {
        var images: [String: UIImage] = [:]
        for agent in agentManager.agents {
            images[agent.id] = AvatarStore.load(for: agent.id)
        }
        avatarImages = images
    }
}

// MARK: - SearchResultRow

private struct SearchResultRow: View {
    let result: ConversationSearchResult

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.gray.opacity(0.3))
                if let img = result.avatarImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .clipShape(Circle())
                } else {
                    Text(result.agentName.prefix(1).uppercased())
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.agentName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if result.message.sender == .user {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                    Text(result.message.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Text(Self.formatter.string(from: result.message.timestamp))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct AgentRow: View {
    @EnvironmentObject var agentManager: AgentManager
    let agent: Agent
    var avatarImage: UIImage? = nil

    private var conversation: Conversation? {
        agentManager.conversations[agent.id]
    }

    private var lastMessage: Message? {
        conversation?.messages.last(where: { $0.type == .text })
    }

    private var activeTransport: String? {
        agentManager.activeTransport(for: agent.id)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(statusColor)
                if let img = avatarImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .clipShape(Circle())
                } else {
                    Text(agent.name.prefix(1).uppercased())
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(agent.name)
                    .font(.headline)

                if let activeTransport = activeTransport {
                    Text("via \(transportShortName(activeTransport))")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                } else if let lastMessage = lastMessage {
                    Text(lastMessage.text)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text("No messages yet")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                if let unreadCount = conversation?.unreadCount, unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(.footnote)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.blue)
                        .clipShape(Capsule())
                }

                statusIndicator
            }
        }
        .padding(.vertical, 4)
    }

    private func transportShortName(_ transport: String) -> String {
        switch transport {
        case "local":           return "Local"
        case "cloudflare":      return "Cloudflare"
        case "tailscale-serve": return "Tailscale"
        default:                return transport
        }
    }

    private var statusColor: Color {
        switch agent.status {
        case .connected:    return .green
        case .disconnected: return .gray
        case .reconnecting: return .orange
        }
    }

    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }
}

#Preview {
    NavigationStack {
        AgentListView(isInChat: .constant(false))
            .environmentObject(AgentManager())
    }
}

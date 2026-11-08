import SwiftUI
import UIKit

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
    var searchText: String = ""
    @Binding var isSearchActive: Bool
    @Environment(\.isSearching) private var isSearching
    /// Called when a search result row is tapped; caller handles dismissing search + navigation.
    var onSearchResultTap: ((ChatDestination) -> Void)?
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
                        Button {
                            // Dismiss the UISearchController before navigating to prevent
                            // it from leaving a phantom back-button in the navigation stack.
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder),
                                to: nil, from: nil, for: nil
                            )
                            onSearchResultTap?(ChatDestination(agentId: result.agentId, scrollToMessageId: result.id))
                        } label: {
                            SearchResultRow(result: result, query: searchText)
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
        }
        .onChange(of: isSearching) { _, active in isSearchActive = active }
        .onAppear { loadAvatars() }
        .sheet(isPresented: Binding(
            get: { agentToConfigureId != nil },
            set: { if !$0 { agentToConfigureId = nil } }
        )) {
            if let id = agentToConfigureId {
                NavigationStack {
                    AgentConfigurationView(agentId: id)
                }
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
    let query: String

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    // Characters of context to show before the match so it appears roughly centred.
    private static let contextLeading = 40

    private static func highlighted(_ fullText: String, query: String) -> Text {
        guard !query.isEmpty else {
            return Text(fullText).font(.caption).foregroundColor(.secondary)
        }
        let nsText = fullText as NSString
        let matchRange = nsText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
        guard matchRange.location != NSNotFound else {
            return Text(fullText).font(.caption).foregroundColor(.secondary)
        }

        // Build a snippet centred on the match: start `contextLeading` chars before it.
        let snippetStart = max(0, Int(matchRange.location) - contextLeading)
        let leadingTrimmed = snippetStart > 0

        // Adjust match range relative to the snippet start.
        let relMatchLoc = matchRange.location - snippetStart
        let relMatchRange = NSRange(location: relMatchLoc, length: matchRange.length)

        let snippet = nsText.substring(from: snippetStart) as NSString
        let before = (leadingTrimmed ? "…" : "") + snippet.substring(to: relMatchRange.location)
        let match  = snippet.substring(with: relMatchRange)
        let after  = snippet.substring(from: relMatchRange.location + relMatchRange.length)

        var result = Text(before).font(.caption).foregroundColor(.secondary)
        result = result + Text(match).font(.caption.bold()).foregroundColor(.accentColor)
        result = result + Text(after).font(.caption).foregroundColor(.secondary)
        return result
    }

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
                    Self.highlighted(result.message.text, query: query)
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
        AgentListView(isInChat: .constant(false), isSearchActive: .constant(false))
            .environmentObject(AgentManager())
    }
}

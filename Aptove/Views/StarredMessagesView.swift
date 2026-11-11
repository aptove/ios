import SwiftUI

struct StarredMessagesView: View {
    @EnvironmentObject private var agentManager: AgentManager
    @AppStorage("appLanguage") private var appLanguage: String = ""
    @Binding var selectedTab: BottomTab
    @Binding var navigationPath: NavigationPath
    @State private var hasBeenSelected = false
    @State private var searchText = ""
    @State private var avatarImages: [String: UIImage] = [:]

    private var starredMessages: [StarredMessage] {
        agentManager.fetchStarredMessages()
    }

    private var filtered: [StarredMessage] {
        guard !searchText.isEmpty else { return starredMessages }
        let query = searchText.lowercased()
        return starredMessages.filter {
            $0.message.text.lowercased().contains(query) ||
            $0.agentName.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !hasBeenSelected || starredMessages.isEmpty {
                    emptyStateView
                } else if filtered.isEmpty {
                    Text("no_search_results")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filtered) { item in
                            StarredMessageRow(
                                item: item,
                                avatarImage: avatarImages[item.agentId],
                                statusColor: statusColor(for: item.agentId),
                                searchQuery: searchText
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedTab = .chat
                                navigationPath = NavigationPath()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    navigationPath.append(ChatDestination(agentId: item.agentId, scrollToMessageId: item.message.id, returnsToStarred: true))
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    agentManager.toggleMessageStar(messageId: item.message.id, agentId: item.agentId)
                                } label: {
                                    Label("unstar_message", systemImage: "star.slash")
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(Bundle.localized("Starred", language: appLanguage))
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("search_starred_prompt"))
            .onAppear {
                loadAvatars()
            }
            .onChange(of: selectedTab) { _, tab in
                guard tab == .starred, !hasBeenSelected else { return }
                // Defer by one frame so the navigation bar initialises in large-title mode
                // (the render that fires when selectedTab changes sees emptyStateView, not List;
                // the Task runs after that frame is committed and swaps in the real content).
                Task { @MainActor in
                    hasBeenSelected = true
                    loadAvatars()
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "star")
                .font(.system(size: 56))
                .foregroundColor(.secondary.opacity(0.5))
            Text("no_starred_messages")
                .font(.title3)
                .fontWeight(.semibold)
            Text("no_starred_messages_subtitle")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private func loadAvatars() {
        for item in starredMessages {
            if avatarImages[item.agentId] == nil {
                avatarImages[item.agentId] = AvatarStore.load(for: item.agentId)
            }
        }
    }

    private func statusColor(for agentId: String) -> Color {
        guard let agent = agentManager.agents.first(where: { $0.id == agentId }) else { return .gray }
        if agent.isAuthenticated == false { return .orange }
        switch agent.status {
        case .connected:    return .green
        case .disconnected: return .gray
        case .reconnecting: return .orange
        }
    }
}

private struct StarredMessageRow: View {
    let item: StarredMessage
    var avatarImage: UIImage?
    var statusColor: Color = .gray
    var searchQuery: String = ""

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

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

        let snippetStart = max(0, Int(matchRange.location) - contextLeading)
        let leadingTrimmed = snippetStart > 0
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
                Circle().fill(statusColor)
                if let img = avatarImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .clipShape(Circle())
                        .padding(3)
                } else {
                    Text(item.agentName.prefix(1).uppercased())
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.agentName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Text(Self.timeFormatter.string(from: item.message.timestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 4) {
                    if item.message.sender == .user {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                    Self.highlighted(item.message.text, query: searchQuery)
                        .lineLimit(2)
                }
            }
        }
    }

}

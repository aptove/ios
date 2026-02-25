import SwiftUI

struct AgentListView: View {
    @EnvironmentObject var agentManager: AgentManager
    @State private var agentToDelete: Agent?
    @State private var showingDeleteConfirmation = false
    
    var body: some View {
        List {
            ForEach(agentManager.agents) { agent in
                NavigationLink {
                    ChatView(agentId: agent.id)
                } label: {
                    AgentRow(agent: agent)
                }
                .contextMenu {
                    NavigationLink {
                        AgentConfigurationView(agentId: agent.id)
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
                    
                    NavigationLink {
                        AgentConfigurationView(agentId: agent.id)
                    } label: {
                        Label("Configure", systemImage: "gear")
                    }
                    .tint(.blue)
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
}

struct AgentRow: View {
    @EnvironmentObject var agentManager: AgentManager
    let agent: Agent

    private var conversation: Conversation? {
        agentManager.conversations[agent.id]
    }

    private var lastMessage: Message? {
        conversation?.messages.last
    }

    private var activeTransport: String? {
        agentManager.activeTransport(for: agent.id)
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 48, height: 48)
                .overlay {
                    Text(agent.name.prefix(1).uppercased())
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }

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

            VStack(alignment: .trailing, spacing: 4) {
                statusIndicator

                if let unreadCount = conversation?.unreadCount, unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func transportShortName(_ transport: String) -> String {
        switch transport {
        case "local":           return "Local"
        case "cloudflare":      return "Cloudflare"
        case "tailscale-serve": return "Tailscale"
        case "tailscale-ip":    return "Tailscale IP"
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
        AgentListView()
            .environmentObject(AgentManager())
    }
}

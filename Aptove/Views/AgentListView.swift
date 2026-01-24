import SwiftUI

struct AgentListView: View {
    @EnvironmentObject var agentManager: AgentManager
    
    var body: some View {
        List {
            ForEach(agentManager.agents) { agent in
                NavigationLink {
                    ChatView(agentId: agent.id)
                } label: {
                    AgentRow(agent: agent)
                }
                .contextMenu {
                    Button(role: .destructive) {
                        Task {
                            await agentManager.removeAgent(agentId: agent.id)
                        }
                    } label: {
                        Label("Disconnect", systemImage: "link.slash")
                    }
                }
            }
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
                
                if let lastMessage = lastMessage {
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
    
    private var statusColor: Color {
        switch agent.status {
        case .connected:
            return .green
        case .disconnected:
            return .gray
        case .error:
            return .red
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

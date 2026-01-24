import SwiftUI

struct ChatView: View {
    @EnvironmentObject var agentManager: AgentManager
    @StateObject private var viewModel: ChatViewModel
    
    let agentId: String
    
    @State private var messageText = ""
    @FocusState private var isInputFocused: Bool
    
    init(agentId: String) {
        self.agentId = agentId
        self._viewModel = StateObject(wrappedValue: ChatViewModel(agentId: agentId))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) { _ in
                    if let lastMessage = viewModel.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            Divider()
            
            HStack(spacing: 12) {
                TextField("Message", text: $messageText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .focused($isInputFocused)
                
                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(messageText.isEmpty ? .gray : .blue)
                }
                .disabled(messageText.isEmpty || viewModel.isSending)
            }
            .padding()
        }
        .navigationTitle(agent?.name ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(agent?.name ?? "Chat")
                        .font(.headline)
                    Text(connectionStatusText)
                        .font(.caption2)
                        .foregroundColor(connectionStatusColor)
                }
            }
        }
        .onAppear {
            viewModel.setAgentManager(agentManager)
            viewModel.loadMessages()
        }
    }
    
    private var agent: Agent? {
        agentManager.agents.first { $0.id == agentId }
    }
    
    private var connectionStatusText: String {
        guard let agent = agent else { return "Unknown" }
        switch agent.status {
        case .connected:
            return "Connected"
        case .disconnected:
            return "Disconnected"
        case .error:
            return "Error"
        }
    }
    
    private var connectionStatusColor: Color {
        guard let agent = agent else { return .gray }
        switch agent.status {
        case .connected:
            return .green
        case .disconnected:
            return .gray
        case .error:
            return .red
        }
    }
    
    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        
        messageText = ""
        isInputFocused = false
        
        Task {
            await viewModel.sendMessage(text)
        }
    }
}

struct MessageBubble: View {
    let message: Message
    
    var body: some View {
        HStack {
            if message.sender == .user {
                Spacer(minLength: 60)
            }
            
            VStack(alignment: message.sender == .user ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .padding(12)
                    .background(backgroundColor)
                    .foregroundColor(textColor)
                    .cornerRadius(16)
                
                HStack(spacing: 4) {
                    Text(timeString)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    if message.sender == .user {
                        statusIcon
                    }
                }
            }
            
            if message.sender == .agent {
                Spacer(minLength: 60)
            }
        }
    }
    
    private var backgroundColor: Color {
        message.sender == .user ? .blue : .gray.opacity(0.2)
    }
    
    private var textColor: Color {
        message.sender == .user ? .white : .primary
    }
    
    private var timeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: message.timestamp)
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        switch message.status {
        case .sending:
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundColor(.secondary)
        case .sent:
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundColor(.secondary)
        case .error:
            Image(systemName: "exclamationmark.circle")
                .font(.caption2)
                .foregroundColor(.red)
        }
    }
}

#Preview {
    NavigationStack {
        ChatView(agentId: "preview-agent")
            .environmentObject(AgentManager())
    }
}

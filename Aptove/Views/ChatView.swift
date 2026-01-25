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
                            MessageBubble(message: message, viewModel: viewModel)
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
    
    private var client: ACPClientWrapper? {
        agentManager.getClient(for: agentId)
    }
    
    private var connectionStatusText: String {
        guard let client = client else { return "Unknown" }
        switch client.connectionState {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting..."
        case .disconnected:
            return "Disconnected"
        case .error:
            return "Error"
        }
    }
    
    private var connectionStatusColor: Color {
        guard let client = client else { return .gray }
        switch client.connectionState {
        case .connected:
            return .green
        case .connecting:
            return .orange
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
    let viewModel: ChatViewModel
    
    var body: some View {
        HStack {
            if message.sender == .user {
                Spacer(minLength: 60)
            }
            
            VStack(alignment: message.sender == .user ? .trailing : .leading, spacing: 4) {
                if message.type == .toolApprovalRequest {
                    toolApprovalView
                } else {
                    textBubbleView
                }
                
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
    
    @ViewBuilder
    private var textBubbleView: some View {
        Text(message.text)
            .padding(12)
            .background(backgroundColor)
            .foregroundColor(textColor)
            .cornerRadius(16)
    }
    
    @ViewBuilder
    private var toolApprovalView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Show the tool request text
            Text(message.text)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(12)
            
            // Show approval buttons if not yet decided
            if let toolApproval = message.toolApproval, toolApproval.approved == nil {
                // Show dynamic options if available
                if !toolApproval.options.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(toolApproval.options) { option in
                            Button {
                                Task {
                                    await viewModel.approveTool(messageId: message.id, optionId: option.optionId)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: option.kind.hasPrefix("allow") ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    Text(option.name)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(option.kind.hasPrefix("allow") ? Color.green : Color.red)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                            }
                        }
                    }
                } else {
                    // Fallback to simple approve/reject if no options provided
                    HStack(spacing: 12) {
                        Button {
                            Task {
                                await viewModel.approveTool(messageId: message.id)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                Text("Approve")
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                        
                        Button {
                            Task {
                                await viewModel.rejectTool(messageId: message.id)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                Text("Reject")
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.red)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                    }
                }
            } else if let toolApproval = message.toolApproval {
                // Show approval status
                HStack {
                    Image(systemName: toolApproval.approved == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                    Text(toolApproval.approved == true ? "Approved" : "Rejected")
                }
                .font(.caption)
                .foregroundColor(toolApproval.approved == true ? .green : .red)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.05))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.orange.opacity(0.3), lineWidth: 2)
        )
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

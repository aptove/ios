import SwiftUI

/// Unified task list showing all scheduled tasks across every connected agent.
/// Tasks are only created from the chat attachment panel.
struct TasksListView: View {
    @Binding var selectedTab: BottomTab

    @EnvironmentObject private var agentManager: AgentManager
    @AppStorage("appLanguage") private var appLanguage: String = ""

    @State private var allTasks: [AgentTask] = []
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var avatarImages: [String: UIImage] = [:]
    @State private var editingTask: AgentTask?

    // Show all tasks — one-time tasks are always enabled; recurring tasks can be enabled/disabled.
    // Disabled recurring tasks are not executed but are not deleted; they remain visible here.
    private var filtered: [AgentTask] {
        guard !searchText.isEmpty else { return allTasks }
        let query = searchText.lowercased()
        return allTasks.filter {
            $0.task.name.lowercased().contains(query) ||
            $0.task.prompt.lowercased().contains(query) ||
            $0.agentName.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if agentManager.agents.isEmpty {
                    emptyAgentsView
                } else if isLoading && allTasks.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if allTasks.isEmpty {
                    emptyTasksView
                } else if filtered.isEmpty {
                    Text("no_search_results")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    taskList
                }
            }
            .navigationTitle(Bundle.localized("Tasks", language: appLanguage))
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("search_tasks_prompt")
            )
            .onAppear { loadTasks() }
            .onChange(of: selectedTab) { _, tab in
                if tab == .tasks { loadTasks() }
            }
            .refreshable { await refreshTasks() }
        }
    }

    // MARK: - Sub-views

    private var emptyAgentsView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("no_agents_connected")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var emptyTasksView: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 56))
                .foregroundColor(.secondary.opacity(0.5))
            Text("no_tasks_yet")
                .font(.title3)
                .fontWeight(.semibold)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var taskList: some View {
        List {
            ForEach(filtered) { item in
                TaskRowView(
                    item: item,
                    avatarImage: avatarImages[item.agentId],
                    statusColor: statusColor(for: item.agentId),
                    searchQuery: searchText
                ) { enabled in
                    toggleTask(item, enabled: enabled)
                }
                .contentShape(Rectangle())
                .onTapGesture { editingTask = item }
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            }
            .onDelete(perform: deleteFiltered)
        }
        .listStyle(.plain)
        .sheet(item: $editingTask) { item in
            TaskCreateView(
                agentId: item.agentId,
                existingTask: item.task,
                onSaved: { updated in
                    if let idx = allTasks.firstIndex(where: { $0.id == item.id }) {
                        allTasks[idx] = AgentTask(task: updated, agentId: item.agentId, agentName: item.agentName)
                    }
                },
                onDeleted: {
                    allTasks.removeAll { $0.id == item.id }
                }
            )
        }
    }

    // MARK: - Data loading

    private func loadTasks() {
        isLoading = true
        let agents = agentManager.agents
        Task {
            var result: [AgentTask] = []
            await withTaskGroup(of: [AgentTask].self) { group in
                for agent in agents {
                    group.addTask {
                        guard let tasks = try? await agentManager.listTasks(for: agent.id) else { return [] }
                        return tasks.map { AgentTask(task: $0, agentId: agent.id, agentName: agent.name) }
                    }
                }
                for await agentTasks in group {
                    result.append(contentsOf: agentTasks)
                }
            }
            let sorted = result.sorted { ($0.task.nextRunAt ?? "") < ($1.task.nextRunAt ?? "") }
            await MainActor.run {
                allTasks = sorted
                isLoading = false
                loadAvatars()
            }
        }
    }

    private func refreshTasks() async {
        let agents = agentManager.agents
        var result: [AgentTask] = []
        await withTaskGroup(of: [AgentTask].self) { group in
            for agent in agents {
                group.addTask {
                    guard let tasks = try? await agentManager.listTasks(for: agent.id) else { return [] }
                    return tasks.map { AgentTask(task: $0, agentId: agent.id, agentName: agent.name) }
                }
            }
            for await agentTasks in group {
                result.append(contentsOf: agentTasks)
            }
        }
        let sorted = result.sorted { ($0.task.nextRunAt ?? "") < ($1.task.nextRunAt ?? "") }
        await MainActor.run {
            allTasks = sorted
            loadAvatars()
        }
    }

    private func loadAvatars() {
        for item in allTasks where avatarImages[item.agentId] == nil {
            avatarImages[item.agentId] = AvatarStore.load(for: item.agentId)
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

    // MARK: - Mutations

    private func toggleTask(_ item: AgentTask, enabled: Bool) {
        Task {
            do {
                let updated = try await agentManager.updateTask(id: item.task.id, enabled: enabled, for: item.agentId)
                await MainActor.run {
                    if let idx = allTasks.firstIndex(where: { $0.id == item.id }) {
                        allTasks[idx] = AgentTask(task: updated, agentId: item.agentId, agentName: item.agentName)
                    }
                }
            } catch {
                print("Failed to toggle task: \(error)")
            }
        }
    }

    private func deleteFiltered(at offsets: IndexSet) {
        let toDelete = offsets.map { filtered[$0] }
        for item in toDelete {
            allTasks.removeAll { $0.id == item.id }
        }
        for item in toDelete {
            Task {
                do {
                    try await agentManager.deleteTask(id: item.task.id, for: item.agentId)
                } catch {
                    print("Failed to delete task \(item.task.id): \(error)")
                    loadTasks()
                }
            }
        }
    }
}

// MARK: - AgentTask wrapper

private struct AgentTask: Identifiable {
    var id: String { task.id }
    let task: ScheduledTask
    let agentId: String
    let agentName: String
}

// MARK: - Task Row

private struct TaskRowView: View {
    let item: AgentTask
    var avatarImage: UIImage?
    var statusColor: Color = .gray
    var searchQuery: String = ""
    var onToggle: ((Bool) -> Void)? = nil

    @AppStorage("appLanguage") private var appLanguage: String = ""

    private static let isoFormatter = ISO8601DateFormatter()
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
    private static let pastDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    private var task: ScheduledTask { item.task }

    private var isOneTime: Bool {
        if case .once = task.schedule { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 12) {
            agentAvatar

            VStack(alignment: .leading, spacing: 4) {
                // Agent name + toggle
                HStack {
                    Text(item.agentName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    if isOneTime {
                        // One-time tasks are always enabled and cannot be disabled
                        Toggle("", isOn: .constant(true))
                            .labelsHidden()
                            .disabled(true)
                    } else {
                        Toggle("", isOn: Binding(
                            get: { task.enabled },
                            set: { onToggle?($0) }
                        ))
                        .labelsHidden()
                    }
                }

                // Task name
                Text(task.name)
                    .font(.body)
                    .lineLimit(1)

                // Type badge + schedule summary
                HStack(spacing: 6) {
                    Text(isOneTime
                         ? Bundle.localized("task_type_once", language: appLanguage)
                         : Bundle.localized("task_type_repeating", language: appLanguage))
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(isOneTime ? Color.orange.opacity(0.15) : Color.blue.opacity(0.15))
                        .foregroundStyle(isOneTime ? .orange : .blue)
                        .clipShape(Capsule())

                    Text(task.schedule.localizedSummary(language: appLanguage))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Next run / last run
                HStack(spacing: 12) {
                    if let nextRun = task.nextRunAt,
                       let date = Self.isoFormatter.date(from: nextRun) {
                        Label {
                            Text(date, style: .relative)
                        } icon: {
                            Image(systemName: "arrow.right.circle")
                        }
                        .font(.caption2)
                        .foregroundStyle(.green)
                    }
                    if let lastRun = task.lastRunAt,
                       let date = Self.isoFormatter.date(from: lastRun) {
                        Label {
                            Text(Self.pastDateFormatter.string(from: date))
                        } icon: {
                            Image(systemName: "checkmark.circle")
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var agentAvatar: some View {
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
    }
}

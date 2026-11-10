import SwiftUI
import Speech

/// Sheet for creating a new scheduled task or editing an existing one.
/// - Create mode: `existingTask` is nil. Left button = Cancel, right = Save.
/// - Edit mode:   `existingTask` is set. Left button = Delete (destructive), right = Save.
struct TaskCreateView: View {
    let agentId: String
    var existingTask: ScheduledTask? = nil
    var onSaved: ((ScheduledTask) -> Void)? = nil
    var onDeleted: (() -> Void)? = nil

    @EnvironmentObject private var agentManager: AgentManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var appLanguage: String = ""
    @AppStorage("voiceLanguage") private var voiceLanguage: String = "en-US"

    @State private var name: String
    @State private var prompt: String
    @State private var scheduleType: ScheduleType
    @State private var selectedDate: Date
    @State private var selectedTime: Date
    @State private var dayOfWeek: Int
    @State private var dayOfMonth: Int
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var showSuccess = false
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?
    @State private var isCorrectingTranscript = false
    @State private var voiceTarget: VoiceTarget = .prompt
    @StateObject private var voiceViewModel = VoiceInputViewModel()
    @FocusState private var isNameFocused: Bool
    @FocusState private var isPromptFocused: Bool

    private var isEditMode: Bool { existingTask != nil }

    private var isVoiceActive: Bool {
        voiceViewModel.recordingState.isActiveRecording || isCorrectingTranscript
    }

    enum ScheduleType: String, CaseIterable {
        case once, daily, weekly, monthly
        var localizationKey: String { "task_schedule_\(rawValue)" }
        func localizedLabel(language: String) -> String {
            Bundle.localized(localizationKey, language: language)
        }
    }

    private enum VoiceTarget { case name, prompt }

    init(agentId: String,
         existingTask: ScheduledTask? = nil,
         onSaved: ((ScheduledTask) -> Void)? = nil,
         onDeleted: (() -> Void)? = nil) {
        self.agentId = agentId
        self.existingTask = existingTask
        self.onSaved = onSaved
        self.onDeleted = onDeleted

        if let task = existingTask {
            _name = State(initialValue: task.name)
            _prompt = State(initialValue: task.prompt)
            switch task.schedule {
            case .once(let at):
                _scheduleType = State(initialValue: .once)
                let d = ISO8601DateFormatter().date(from: at) ?? Date().addingTimeInterval(3600)
                _selectedDate = State(initialValue: d)
                _selectedTime = State(initialValue: Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date())
                _dayOfWeek = State(initialValue: Calendar.current.component(.weekday, from: Date()) - 1)
                _dayOfMonth = State(initialValue: 1)
            case .recurring(let freq, let time, let dow, let dom, _):
                let st: ScheduleType
                switch freq {
                case .daily:   st = .daily
                case .weekly:  st = .weekly
                case .monthly: st = .monthly
                }
                _scheduleType = State(initialValue: st)
                let parts = time.split(separator: ":").compactMap { Int($0) }
                let t = Calendar.current.date(from: DateComponents(
                    hour: parts.count > 0 ? parts[0] : 9,
                    minute: parts.count > 1 ? parts[1] : 0
                )) ?? Date()
                _selectedTime = State(initialValue: t)
                _selectedDate = State(initialValue: Date().addingTimeInterval(3600))
                _dayOfWeek = State(initialValue: dow ?? (Calendar.current.component(.weekday, from: Date()) - 1))
                _dayOfMonth = State(initialValue: dom ?? 1)
            }
        } else {
            _name = State(initialValue: "")
            _prompt = State(initialValue: "")
            _scheduleType = State(initialValue: .daily)
            _selectedDate = State(initialValue: Date().addingTimeInterval(3600))
            _selectedTime = State(initialValue: Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date())
            _dayOfWeek = State(initialValue: Calendar.current.component(.weekday, from: Date()) - 1)
            _dayOfMonth = State(initialValue: 1)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Name field
                Section {
                    HStack(spacing: 10) {
                        TextField("task_name_placeholder", text: $name)
                            .focused($isNameFocused)
                        nameMicButton
                    }
                    if isCorrectingTranscript && voiceTarget == .name {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.8)
                            Text("memory_correcting")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if voiceViewModel.recordingState.isActiveRecording && voiceTarget == .name {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform")
                                .foregroundStyle(.red)
                                .symbolEffect(.variableColor.iterative)
                            Text("memory_recording")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                // MARK: Prompt field
                Section {
                    VStack(spacing: 0) {
                        TextEditor(text: $prompt)
                            .focused($isPromptFocused)
                            .frame(minHeight: 100)
                            .overlay(alignment: .topLeading) {
                                if prompt.isEmpty {
                                    Text("task_prompt_placeholder")
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 8)
                                        .padding(.leading, 4)
                                        .allowsHitTesting(false)
                                }
                            }

                        Divider()

                        HStack(spacing: 16) {
                            promptVoiceStatusView
                            Spacer()
                            promptMicButton
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 12)
                    }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

                // MARK: Schedule
                Section("Schedule") {
                    Picker("schedule_type", selection: $scheduleType) {
                        ForEach(ScheduleType.allCases, id: \.self) { type in
                            Text(type.localizedLabel(language: appLanguage)).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: scheduleType) { _, _ in hideKeyboard() }

                    switch scheduleType {
                    case .once:
                        DatePicker("task_date", selection: $selectedDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                            .onChange(of: selectedDate) { _, _ in hideKeyboard() }
                    case .daily:
                        DatePicker("task_time", selection: $selectedTime, displayedComponents: .hourAndMinute)
                            .onChange(of: selectedTime) { _, _ in hideKeyboard() }
                    case .weekly:
                        DatePicker("task_time", selection: $selectedTime, displayedComponents: .hourAndMinute)
                            .onChange(of: selectedTime) { _, _ in hideKeyboard() }
                        Picker("task_day_of_week", selection: $dayOfWeek) {
                            ForEach(0..<7, id: \.self) { day in
                                Text(Calendar.current.weekdaySymbols[day]).tag(day)
                            }
                        }
                        .onChange(of: dayOfWeek) { _, _ in hideKeyboard() }
                    case .monthly:
                        DatePicker("task_time", selection: $selectedTime, displayedComponents: .hourAndMinute)
                            .onChange(of: selectedTime) { _, _ in hideKeyboard() }
                        Picker("task_day_of_month", selection: $dayOfMonth) {
                            ForEach(1...28, id: \.self) { day in
                                Text("\(day)").tag(day)
                            }
                        }
                        .onChange(of: dayOfMonth) { _, _ in hideKeyboard() }
                    }
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle(Bundle.localized("task_view_title", language: appLanguage))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isEditMode {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Text("Delete")
                                .foregroundStyle(.red)
                        }
                        .disabled(isDeleting || isSaving)
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving || isDeleting {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button("Save") { saveTask() }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || isCorrectingTranscript)
                            .fontWeight(.semibold)
                    }
                }
            }
            .confirmationDialog("task_delete_confirm", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteTask() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("task_delete_message")
            }
            .overlay(alignment: .bottom) {
                if showSuccess {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("task_saved")
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.3), value: showSuccess)
        }
    }

    // MARK: - Name mic button (inline)

    private var nameMicButton: some View {
        let isRecordingForName = voiceViewModel.recordingState.isActiveRecording && voiceTarget == .name
        return Button {
            if isRecordingForName {
                voiceViewModel.stopRecording()
            } else {
                startVoiceInput(for: .name)
            }
        } label: {
            Image(systemName: isRecordingForName ? "stop.circle.fill" : "mic.circle")
                .font(.system(size: 22))
                .foregroundStyle(isRecordingForName ? .red : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(isVoiceActive && !isRecordingForName)
    }

    // MARK: - Prompt voice row

    @ViewBuilder
    private var promptVoiceStatusView: some View {
        if isCorrectingTranscript && voiceTarget == .prompt {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.8)
                Text("memory_correcting")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            switch voiceViewModel.recordingState {
            case .recording where voiceTarget == .prompt:
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.red)
                        .symbolEffect(.variableColor.iterative)
                    Text("memory_recording")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            case .processing where voiceTarget == .prompt:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.8)
                    Text("memory_transcribing")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            case .error(let msg):
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
            default:
                Text("memory_tap_to_dictate")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var promptMicButton: some View {
        let isRecordingForPrompt = voiceViewModel.recordingState.isActiveRecording && voiceTarget == .prompt
        return Button {
            if isRecordingForPrompt {
                voiceViewModel.stopRecording()
            } else {
                startVoiceInput(for: .prompt)
            }
        } label: {
            Image(systemName: isRecordingForPrompt ? "stop.circle.fill" : "mic.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(isRecordingForPrompt ? .red : .blue)
        }
        .disabled(isVoiceActive && !isRecordingForPrompt)
    }

    // MARK: - Shared voice input

    private func startVoiceInput(for target: VoiceTarget) {
        voiceTarget = target
        voiceViewModel.onTranscriptReady = { transcript in
            voiceViewModel.recordingState = .idle
            isCorrectingTranscript = true
            Task {
                let corrected = await agentManager.correctVoiceTranscript(
                    transcript, for: agentId, language: voiceLanguage)
                await MainActor.run {
                    switch target {
                    case .name:
                        name = corrected
                    case .prompt:
                        prompt += (prompt.isEmpty ? "" : " ") + corrected
                    }
                    isCorrectingTranscript = false
                }
            }
        }
        voiceViewModel.startRecording()
    }

    // MARK: - Keyboard

    private func hideKeyboard() {
        isNameFocused = false
        isPromptFocused = false
    }

    // MARK: - Save / Delete

    private func saveTask() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return }

        isSaving = true
        errorMessage = nil
        let schedule = buildSchedule()

        Task {
            do {
                let saved: ScheduledTask
                if let existing = existingTask {
                    // One-time tasks must always be enabled — force it on save.
                    let enabledOverride: Bool? = scheduleType == .once ? true : nil
                    saved = try await agentManager.updateTask(
                        id: existing.id,
                        name: trimmedName,
                        prompt: trimmedPrompt,
                        schedule: schedule,
                        enabled: enabledOverride,
                        for: agentId
                    )
                } else {
                    saved = try await agentManager.createTask(
                        name: trimmedName, prompt: trimmedPrompt, schedule: schedule, for: agentId)
                }
                await MainActor.run {
                    onSaved?(saved)
                    showSuccess = true
                    isSaving = false
                }
                try? await Task.sleep(for: .seconds(1.5))
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSaving = false
                }
            }
        }
    }

    private func deleteTask() {
        guard let existing = existingTask else { return }
        isDeleting = true
        Task {
            do {
                try await agentManager.deleteTask(id: existing.id, for: agentId)
                await MainActor.run {
                    onDeleted?()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isDeleting = false
                }
            }
        }
    }

    private func buildSchedule() -> TaskSchedule {
        let tz = TimeZone.current.identifier
        let timeComponents = Calendar.current.dateComponents([.hour, .minute], from: selectedTime)
        let timeString = String(format: "%02d:%02d", timeComponents.hour ?? 0, timeComponents.minute ?? 0)

        switch scheduleType {
        case .once:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return .once(at: formatter.string(from: selectedDate))
        case .daily:
            return .recurring(frequency: .daily, time: timeString, dayOfWeek: nil, dayOfMonth: nil, timezone: tz)
        case .weekly:
            return .recurring(frequency: .weekly, time: timeString, dayOfWeek: dayOfWeek, dayOfMonth: nil, timezone: tz)
        case .monthly:
            return .recurring(frequency: .monthly, time: timeString, dayOfWeek: nil, dayOfMonth: dayOfMonth, timezone: tz)
        }
    }
}

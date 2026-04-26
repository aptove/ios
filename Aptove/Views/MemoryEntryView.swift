import SwiftUI
import Speech

/// Sheet that lets the user add a memory entry (text or voice) and send it to the bridge.
struct MemoryEntryView: View {
    let agentId: String
    @EnvironmentObject private var agentManager: AgentManager
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @StateObject private var voiceViewModel = VoiceInputViewModel()
    @FocusState private var isTextFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .focused($isTextFocused)
                    .padding(12)
                    .frame(minHeight: 160)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("What do you want the AI to remember?")
                                .foregroundStyle(.secondary)
                                .padding(.top, 20)
                                .padding(.leading, 16)
                                .allowsHitTesting(false)
                        }
                    }

                Divider()

                // Voice input row
                HStack(spacing: 16) {
                    voiceStatusView
                    Spacer()
                    recordButton
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Color(.systemGroupedBackground))

                if let err = errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
            }
            .navigationTitle("Add Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveMemory() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                        .fontWeight(.semibold)
                }
            }
            .onAppear { isTextFocused = true }
            .onChange(of: voiceViewModel.recordingState) { _, state in
                if case .processing = state { /* waiting for transcript */ }
            }
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var voiceStatusView: some View {
        switch voiceViewModel.recordingState {
        case .recording:
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .foregroundStyle(.red)
                    .symbolEffect(.variableColor.iterative)
                Text("Recording…")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        case .processing:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.8)
                Text("Transcribing…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .error(let msg):
            Text(msg)
                .font(.caption)
                .foregroundStyle(.red)
        default:
            Text("Tap mic to dictate")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var recordButton: some View {
        let isRecording = voiceViewModel.recordingState.isActiveRecording
        return Button {
            if isRecording {
                voiceViewModel.stopRecording()
            } else {
                voiceViewModel.onTranscriptReady = { transcript in
                    text += (text.isEmpty ? "" : " ") + transcript
                    voiceViewModel.recordingState = .idle
                }
                voiceViewModel.startRecording()
            }
        } label: {
            Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(isRecording ? .red : .blue)
        }
    }

    // MARK: - Actions

    private func saveMemory() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSending = true
        Task {
            await agentManager.sendMemoryEntry(trimmed, for: agentId)
            await MainActor.run {
                isSending = false
                dismiss()
            }
        }
    }
}

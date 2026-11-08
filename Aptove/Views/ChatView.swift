import SwiftUI
import MarkdownUI
import PhotosUI
import ACPModel
import UniformTypeIdentifiers
import AVFoundation

struct ChatView: View {
    @EnvironmentObject var agentManager: AgentManager
    @StateObject private var viewModel: ChatViewModel
    @StateObject private var voiceViewModel = VoiceInputViewModel()
    @AppStorage("voiceLanguage") private var voiceLanguage: String = "en-US"
    @AppStorage("isVerboseMode") private var isVerboseMode: Bool = true

    let agentId: String
    @Binding var isInChat: Bool

    @State private var messageText = ""
    @State private var isInputFocused: Bool = false
    @State private var selectedImages: [UIImage] = []
    @State private var showPhotoPicker = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var selectedFiles: [FileAttachment] = []
    @State private var showFilePicker = false
    @State private var showCamera = false
    @State private var showCameraPermissionDenied = false
    @State private var fileErrorMessage: String? = nil
    @State private var showingFileError = false
    @State private var commandQuery: String? = nil // nil = picker hidden
    @State private var showAttachmentPanel = false
    @State private var showMemoryEntry = false
    @State private var showingAgentConfig = false
    @State private var loadedAvatarImage: UIImage?

    @Environment(\.dismiss) private var dismiss

    init(agentId: String, isInChat: Binding<Bool>) {
        self.agentId = agentId
        self._isInChat = isInChat
        self._viewModel = StateObject(wrappedValue: ChatViewModel(agentId: agentId))
    }

    private var displayedMessages: [Message] {
        guard !isVerboseMode else { return viewModel.messages }
        return viewModel.messages.filter { $0.type != .thought && $0.type != .toolStatus }
    }

    private var newMessageStartId: String? {
        agentManager.newMessageStartIds[agentId]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Custom navigation header — replaces system nav bar so we have
            // full control over the avatar + name layout.
            chatHeaderView
            Divider()

            if let warning = agentManager.bridgeMismatchWarnings[agentId], !warning.isEmpty {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.12))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(displayedMessages) { message in
                            if message.id == newMessageStartId {
                                NewMessagesSeparator()
                            }
                            MessageBubble(message: message, viewModel: viewModel)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) { oldCount, _ in
                    if let lastMessage = viewModel.messages.last {
                        if oldCount == 0 {
                            // Initial load — jump instantly, no animation
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        } else {
                            withAnimation {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            
            Divider()

            VStack(spacing: 0) {
                if voiceViewModel.recordingState.isActiveRecording {
                    let isPaused = { if case .paused = voiceViewModel.recordingState { return true }; return false }()
                    VStack(spacing: 8) {
                        // Waveform preview row
                        HStack(spacing: 10) {
                            Image(systemName: "play.fill")
                                .foregroundColor(.secondary)
                                .font(.caption)
                            WaveformView(samples: voiceViewModel.waveformSamples)
                            Text(timeString(voiceViewModel.elapsedSeconds))
                                .font(.subheadline.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(Color(.systemGray5).opacity(0.8))
                        .clipShape(Capsule())
                        .padding(.horizontal)
                        .padding(.top, 8)

                        // Action row
                        HStack {
                            Button {
                                voiceViewModel.cancelRecording()
                            } label: {
                                Image(systemName: "trash")
                                    .font(.title2)
                                    .foregroundColor(.red)
                            }
                            Spacer()
                            Button {
                                if isPaused {
                                    voiceViewModel.resumeRecording()
                                } else {
                                    voiceViewModel.pauseRecording()
                                }
                            } label: {
                                Image(systemName: isPaused ? "mic.fill" : "pause.fill")
                                    .font(.title2)
                                    .foregroundColor(.red)
                                    .scaleEffect(isPaused ? 1.0 : 1.0 + CGFloat(voiceViewModel.waveformSamples.last ?? 0) * 0.4)
                                    .animation(.easeOut(duration: 0.08), value: voiceViewModel.waveformSamples.last)
                            }
                            Spacer()
                            Button {
                                voiceViewModel.stopRecording()
                            } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.largeTitle)
                                    .foregroundColor(.green)
                            }
                        }
                        .padding(.horizontal, 32)
                        .padding(.bottom, 12)
                    }
                } else if case .processing = voiceViewModel.recordingState {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("Converting speech to text...")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                } else {
                    if !selectedImages.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(selectedImages.indices, id: \.self) { i in
                                    ZStack(alignment: .topTrailing) {
                                        Image(uiImage: selectedImages[i])
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 64, height: 64)
                                            .clipped()
                                            .cornerRadius(8)
                                        Button {
                                            selectedImages.remove(at: i)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.white)
                                                .background(Color.black.opacity(0.4).clipShape(Circle()))
                                        }
                                        .padding(4)
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                        .frame(height: 80)
                        .background(Color(.systemGroupedBackground))
                    }

                    if !selectedFiles.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(selectedFiles.indices, id: \.self) { i in
                                    fileChip(for: selectedFiles[i]) {
                                        selectedFiles.remove(at: i)
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                        .padding(.vertical, 6)
                        .background(Color(.systemGroupedBackground))
                    }

                    commandPickerView

                    if showAttachmentPanel {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 16) {
                            attachmentItem(icon: "photo", label: "attachment_photos", color: .blue) {
                                showAttachmentPanel = false
                                showPhotoPicker = true
                            }
                            attachmentItem(icon: "camera", label: "camera_label", color: .indigo) {
                                showAttachmentPanel = false
                                handleCameraAction()
                            }
                            attachmentItem(icon: "paperclip", label: "files_label", color: .green) {
                                showAttachmentPanel = false
                                showFilePicker = true
                            }
                            attachmentItem(icon: nil, slashLabel: "/", label: "attachment_commands", color: .purple) {
                                showAttachmentPanel = false
                                commandQuery = ""
                                isInputFocused = true
                            }
                            attachmentItem(icon: "brain", label: "attachment_memory", color: .orange) {
                                showAttachmentPanel = false
                                showMemoryEntry = true
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background(Color(.systemBackground))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    HStack(spacing: 12) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showAttachmentPanel.toggle()
                                if showAttachmentPanel { commandQuery = nil }
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.title2)
                                .foregroundColor(showAttachmentPanel ? .accentColor : .blue)
                        }

                        MessageTextField(text: $messageText, isFocused: $isInputFocused) { transcript in
                            voiceViewModel.recordingState = .processing
                            Task { await viewModel.sendVoiceCorrectionRequest(transcript) }
                        }

                        if messageText.isEmpty {
                            Button {
                                voiceViewModel.onTranscriptReady = { transcript in
                                    Task { await viewModel.sendVoiceCorrectionRequest(transcript) }
                                }
                                voiceViewModel.startRecording()
                            } label: {
                                Image(systemName: "mic")
                                    .font(.title2)
                                    .foregroundColor(.blue)
                            }
                            .disabled(viewModel.isVoiceCorrectionPending)
                        } else {
                            Button {
                                sendMessage()
                            } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.blue)
                            }
                            .disabled(viewModel.isSending)
                        }
                    }
                    .padding()
                }
            }
            .photosPicker(isPresented: $showPhotoPicker,
                          selection: $pickerItems,
                          maxSelectionCount: 10,
                          matching: .images)
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.pdf, .plainText, .commaSeparatedText, .json, .rtf],
                allowsMultipleSelection: true
            ) { result in
                Task {
                    await handleFileImporterResult(result)
                }
            }
            .alert("file_error_title", isPresented: $showingFileError) {
                Button("OK", role: .cancel) { fileErrorMessage = nil }
            } message: {
                Text(fileErrorMessage ?? "")
            }
            .sheet(isPresented: $showMemoryEntry) {
                MemoryEntryView(agentId: agentId)
                    .environmentObject(agentManager)
            }
            .onChange(of: pickerItems) { _, items in
                // Guard prevents re-triggering when we clear pickerItems below
                guard !items.isEmpty else { return }
                Task {
                    var loaded: [UIImage] = []
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let img = UIImage(data: data) {
                            loaded.append(img)
                        }
                    }
                    selectedImages = loaded
                    pickerItems = []
                }
            }
        }
        .onChange(of: messageText) { _, text in
            if !text.isEmpty { showAttachmentPanel = false }
            if text.hasPrefix("/"), !text.contains(" ") {
                commandQuery = String(text.dropFirst())
            } else {
                commandQuery = nil
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showingAgentConfig) {
            AgentConfigurationView(agentId: agentId)
        }
        .onAppear {
            isInChat = true
            agentManager.activeChatAgentId = agentId
            agentManager.clearUnreadCount(agentId: agentId)
            viewModel.setAgentManager(agentManager)
            viewModel.loadMessages()
            voiceViewModel.updateLocale(voiceLanguage)
            viewModel.voiceLanguage = voiceLanguage
            loadedAvatarImage = AvatarStore.load(for: agentId)
        }
        .onChange(of: voiceLanguage) { _, newLang in
            voiceViewModel.updateLocale(newLang)
            viewModel.voiceLanguage = newLang
        }
        .onChange(of: agentManager.conversations[agentId]?.messages.count ?? 0) { oldCount, newCount in
            // Sync ChatViewModel when AgentManager's conversation grows from outside
            // (e.g. cold-start replay after foregrounding into an open chat).
            guard newCount > oldCount else { return }
            viewModel.loadMessages()
        }
        .onDisappear {
            isInChat = false
            // Do NOT clear activeChatAgentId here — onDisappear fires when the app
            // backgrounds (not just on navigation). Keeping it set lets
            // onColdStartReplayComplete place the separator correctly on foreground.
            // activeChatAgentId is cleared in ContentView when navigationPath becomes
            // empty (user actually navigated back to the agent list).
            agentManager.newMessageStartIds.removeValue(forKey: agentId)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCapture(isPresented: $showCamera) { image in
                selectedImages.append(image)
            }
            .ignoresSafeArea()
        }
        .alert("camera_permission_denied_title", isPresented: $showCameraPermissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("camera_chat_permission_denied_message")
        }
        .onChange(of: viewModel.voiceCorrectedText) { _, correctedText in
            if let text = correctedText {
                messageText = text
                isInputFocused = true
                Task { @MainActor in viewModel.voiceCorrectedText = nil }
                // Always reset recording state when text is ready — handles both
                // successful AI correction and immediate fallback (no/lost connection).
                voiceViewModel.recordingState = .idle
            }
        }
        .onChange(of: viewModel.isVoiceCorrectionPending) { _, pending in
            if !pending {
                voiceViewModel.recordingState = .idle
            }
        }
    }
    
    private func timeString(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var agentName: String {
        agentManager.agents.first { $0.id == agentId }?.name ?? String(localized: "chat_default_title")
    }

    private var agentStatusColor: Color {
        switch agentManager.agents.first(where: { $0.id == agentId })?.status {
        case .connected:    return .green
        case .reconnecting: return .orange
        default:            return .gray
        }
    }

    // MARK: - Custom header

    private var chatHeaderView: some View {
        HStack(spacing: 4) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 44, height: 44)
            }

            Button { showingAgentConfig = true } label: {
                HStack(spacing: 10) {
                    agentAvatarCircle(size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(agentName)
                            .font(.headline)
                            .foregroundColor(.primary)
                        if viewModel.showSessionIndicator {
                            Text(viewModel.sessionWasResumed == true
                                 ? String(localized: "chat_session_resumed")
                                 : String(localized: "chat_new_session"))
                                .font(.caption)
                                .foregroundColor(viewModel.sessionWasResumed == true ? .blue : .secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private func agentAvatarCircle(size: CGFloat) -> some View {
        ZStack {
            Circle().fill(agentStatusColor)
            if let img = loadedAvatarImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                Text(agentName.prefix(1).uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .frame(width: size, height: size)
    }
    
    private func applyCommand(_ command: AvailableCommand) {
        let hasInput = command.input != nil
        messageText = hasInput ? "/\(command.name) " : "/\(command.name)"
        commandQuery = nil
        if hasInput { isInputFocused = true }
    }

    @ViewBuilder
    private func attachmentItem(icon: String?, slashLabel: String? = nil, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(color).frame(width: 56, height: 56)
                    if let icon {
                        Image(systemName: icon).foregroundColor(.white).font(.title2)
                    } else if let slashLabel {
                        Text(slashLabel).foregroundColor(.white).font(.system(.title2, design: .monospaced))
                    }
                }
                Text(LocalizedStringKey(label)).font(.caption).foregroundColor(.primary)
            }
        }
    }

    @ViewBuilder
    private var commandPickerView: some View {
        let suggestions = viewModel.filteredCommands(for: commandQuery ?? "")
        if commandQuery != nil && !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(suggestions, id: \.name) { command in
                    Button {
                        applyCommand(command)
                    } label: {
                        HStack(spacing: 8) {
                            Text("/")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(command.name)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(.primary)
                                Text(command.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    Divider()
                }
            }
            .background(Color(.systemBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
            .padding(.top, 4)
        }
    }

    private func handleCameraAction() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            showCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { showCamera = true } else { showCameraPermissionDenied = true }
                }
            }
        case .denied, .restricted:
            showCameraPermissionDenied = true
        @unknown default:
            break
        }
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !selectedImages.isEmpty || !selectedFiles.isEmpty else { return }
        let images = selectedImages
        let files = selectedFiles
        messageText = ""
        selectedImages = []
        selectedFiles = []
        isInputFocused = false
        Task {
            await viewModel.sendMessage(text, images: images, files: files)
        }
    }

    private func handleFileImporterResult(_ result: Result<[URL], Error>) async {
        switch result {
        case .failure(let error):
            fileErrorMessage = error.localizedDescription
            showingFileError = true
        case .success(let urls):
            var newFiles: [FileAttachment] = []
            var errorMessages: [String] = []
            for url in urls {
                let gotAccess = url.startAccessingSecurityScopedResource()
                defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    guard data.count <= 10 * 1024 * 1024 else {
                        errorMessages.append(String(format: String(localized: "file_too_large_error"), url.lastPathComponent))
                        continue
                    }
                    let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    newFiles.append(FileAttachment(name: url.lastPathComponent, data: data, mimeType: mimeType))
                } catch {
                    errorMessages.append(String(format: String(localized: "file_load_error"), url.lastPathComponent))
                }
            }
            selectedFiles.append(contentsOf: newFiles)
            if !errorMessages.isEmpty {
                fileErrorMessage = errorMessages.joined(separator: "\n")
                showingFileError = true
            }
        }
    }

    private func fileChip(for file: FileAttachment, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: fileIconName(mimeType: file.mimeType))
                .font(.caption)
                .foregroundColor(.secondary)
            Text(file.name)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 120)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(.systemGray5))
        .cornerRadius(8)
    }
}

private func fileIconName(mimeType: String) -> String {
    if mimeType.contains("pdf") { return "doc.fill" }
    if mimeType.hasPrefix("text/") { return "doc.text.fill" }
    return "doc.fill"
}

// MARK: - MessageTextField

class DictationTextView: UITextView {
    var onDictationResult: ((String) -> Void)?

    // Clear partial live-transcription text, route final transcript to AI.
    override func insertDictationResult(_ dictationResult: [UIDictationPhrase]) {
        text = ""
        let transcript = dictationResult.map(\.text).joined()
        onDictationResult?(transcript)
    }
}

struct MessageTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let onDictationResult: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> DictationTextView {
        let view = DictationTextView()
        view.onDictationResult = onDictationResult
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.isScrollEnabled = false
        view.backgroundColor = UIColor.secondarySystemBackground
        view.layer.cornerRadius = 8
        view.layer.borderWidth = 0.5
        view.layer.borderColor = UIColor.separator.cgColor
        view.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        view.textContainer.lineFragmentPadding = 0
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: DictationTextView, context: Context) -> CGSize? {
        let width = max(proposal.width ?? uiView.bounds.width, 1)
        let lineHeight = uiView.font?.lineHeight ?? 20
        let insets = uiView.textContainerInset
        let maxHeight = lineHeight * 5 + insets.top + insets.bottom
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: min(fitting.height, maxHeight))
    }

    func updateUIView(_ view: DictationTextView, context: Context) {
        // Sync text (skip when showing placeholder)
        if view.textColor != .placeholderText && view.text != text {
            view.text = text
        } else if view.textColor == .placeholderText && !text.isEmpty {
            view.text = text
            view.textColor = .label
        }
        // Enable scrolling once content exceeds 5-line cap
        let insets = view.textContainerInset
        let maxHeight = (view.font?.lineHeight ?? 20) * 5 + insets.top + insets.bottom
        let needed = view.sizeThatFits(CGSize(width: max(view.bounds.width, 1), height: .greatestFiniteMagnitude)).height
        view.isScrollEnabled = needed > maxHeight
        // Focus
        if isFocused && !view.isFirstResponder { view.becomeFirstResponder() }
        else if !isFocused && view.isFirstResponder { view.resignFirstResponder() }
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: MessageTextField
        init(_ parent: MessageTextField) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            if textView.textColor != .placeholderText {
                parent.text = textView.text
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if textView.textColor == .placeholderText {
                textView.text = ""
                textView.textColor = .label
            }
            // Defer the binding write — UIKit can call this synchronously during its own
            // layout pass; mutating a @Binding mid-render triggers "Modifying state during
            // view update". Same pattern as textViewDidEndEditing.
            DispatchQueue.main.async { [weak self] in
                self?.parent.isFocused = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if textView.text.isEmpty {
                textView.text = String(localized: "Message")
                textView.textColor = .placeholderText
            }
            // Defer the binding write — UIKit fires this delegate synchronously inside
            // UIView.resignFirstResponder(), which can be called from SwiftUI's updateUIView
            // pass. Mutating a @Binding mid-render triggers the "Modifying state during view
            // update" warning, so schedule it for the next run-loop turn instead.
            DispatchQueue.main.async { [weak self] in
                self?.parent.isFocused = false
            }
        }
    }
}

struct WaveformView: View {
    let samples: [Float]
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(samples.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.green)
                    .frame(width: 3, height: max(4, CGFloat(samples[i]) * 36 + 4))
                    .animation(.easeOut(duration: 0.08), value: samples[i])
            }
        }
        .frame(height: 44)
    }
}

struct MessageBubble: View {
    let message: Message
    let viewModel: ChatViewModel

    var body: some View {
        let isAgent = message.sender == .agent

        HStack {
            if !isAgent {
                Spacer(minLength: 60)
            }

            VStack(alignment: isAgent ? .leading : .trailing, spacing: 4) {
                if message.type == .toolApprovalRequest {
                    toolApprovalView
                } else if message.type == .thought {
                    thoughtBubbleView
                } else if message.type == .toolStatus {
                    toolStatusBubbleView
                } else if message.type == .slashCommand {
                    slashCommandBubbleView
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

            if isAgent {
                Spacer(minLength: 0)
            }
        }
    }
    
    @ViewBuilder
    private var textBubbleView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let images = message.images, !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(images.indices, id: \.self) { i in
                            if let uiImage = UIImage(data: images[i]) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 80, height: 80)
                                    .clipped()
                                    .cornerRadius(8)
                            }
                        }
                    }
                }
            }
            if let files = message.files, !files.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(files.indices, id: \.self) { i in
                        HStack(spacing: 6) {
                            Image(systemName: fileIconName(mimeType: files[i].mimeType))
                                .font(.caption)
                            Text(files[i].name)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(6)
                    }
                }
            }
            if !message.text.isEmpty {
                Markdown(message.text)
                    .markdownBlockStyle(\.codeBlock) { CodeBlockView(config: $0) }
            }
        }
        .padding(12)
        .background(backgroundColor)
        .foregroundColor(textColor)
        .cornerRadius(16)
        .contextMenu {
            if message.sender == .agent && !message.text.isEmpty {
                Button {
                    UIPasteboard.general.string = message.text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
        }
    }

    @ViewBuilder
    private var slashCommandBubbleView: some View {
        HStack(spacing: 4) {
            Text("/")
                .font(.system(.subheadline, design: .monospaced))
                .foregroundColor(.accentColor)
            Text(message.text.drop(while: { $0 == "/" }).trimmingCharacters(in: .whitespaces))
                .font(.system(.subheadline, design: .monospaced))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.systemGray5))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var thoughtBubbleView: some View {
        Text(message.text)
            .font(.subheadline)
            .italic()
            .padding(10)
            .background(Color.purple.opacity(0.1))
            .foregroundColor(.purple)
            .cornerRadius(12)
    }

    @ViewBuilder
    private var toolStatusBubbleView: some View {
        HStack(spacing: 8) {
            Image(systemName: "gear")
            Text(message.text)
                .font(.subheadline)
        }
        .padding(10)
        .background(Color.blue.opacity(0.1))
        .foregroundColor(.blue)
        .cornerRadius(12)
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
    
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private var timeString: String {
        Self.timeFormatter.string(from: message.timestamp)
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

private struct NewMessagesSeparator: View {
    var body: some View {
        HStack {
            VStack { Divider() }
            Text("new_messages_separator")
                .font(.caption)
                .foregroundColor(.accentColor)
                .padding(.horizontal, 8)
                .fixedSize()
            VStack { Divider() }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        ChatView(agentId: "preview-agent", isInChat: .constant(true))
            .environmentObject(AgentManager())
    }
}

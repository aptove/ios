import Foundation
import SwiftUI
import UIKit
import ACPModel

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var isSending = false
    @Published var sessionWasResumed: Bool? = nil  // nil = unknown, true = resumed, false = new
    @Published var showSessionIndicator = false
    @Published var isVoiceCorrectionPending = false
    @Published var voiceCorrectedText: String? = nil
    @Published var availableCommands: [AvailableCommand] = []
    
    let agentId: String
    var voiceLanguage: String = "en-US"
    private var agentManager: AgentManager?
    private var isToolApprovalHandlerSetup = false
    private var cachedClient: ACPClientWrapper?

    /// Expose the current ACP client for file browser access.
    var acpClient: ACPClientWrapper? { cachedClient }
    private var isPrewarmingClient = false
    private var hasShownSessionIndicator = false  // Track if we've already shown the indicator this view session
    
    /// Approval cards waiting to be shown after the current active card is answered.
    private var approvalQueue: [Message] = []

    /// Track active tasks for cleanup
    private var prewarmTask: Task<Void, Never>?
    private var sendMessageTask: Task<Void, Never>?

    /// Throttle updateConversation() during streaming to avoid main-thread thrash.
    private var lastConversationUpdateTime: Date = .distantPast
    private static let streamingUpdateInterval: TimeInterval = 0.3

    private static let codeFenceRegex = try? NSRegularExpression(
        pattern: #"```(?:json)?\s*(\{[\s\S]*?\})\s*```"#
    )
    
    init(agentId: String) {
        self.agentId = agentId
    }
    
    deinit {
        // Cancel any outstanding tasks
        prewarmTask?.cancel()
        sendMessageTask?.cancel()
    }
    
    func setAgentManager(_ manager: AgentManager) {
        self.agentManager = manager
        print("💬 ChatViewModel: AgentManager set for agent \(agentId)")
        
        // Pre-warm client in background (fire-and-forget, don't await!)
        prewarmClient()
    }
    
    /// Cancel any active operations (call when view disappears)
    func cleanup() {
        prewarmTask?.cancel()
        sendMessageTask?.cancel()
    }
    
    /// Pre-warm the client in background without blocking the main thread
    /// This includes establishing the WebSocket connection so first message is instant
    private func prewarmClient() {
        guard !isPrewarmingClient, cachedClient == nil else { return }
        isPrewarmingClient = true
        
        print("🔥 ChatViewModel: Starting client pre-warm for agent \(agentId)")
        
        // Store task for potential cancellation
        prewarmTask = Task { [weak self, agentManager, agentId] in
            print("🔥 ChatViewModel: Pre-warm task started")
            
            // Check for cancellation before expensive operations
            guard !Task.isCancelled else {
                print("🔥 ChatViewModel: Pre-warm cancelled before getClient")
                return
            }
            
            // Use getConnectedClient which handles session persistence
            let client = await agentManager?.getConnectedClient(for: agentId)
            print("🔥 ChatViewModel: Pre-warm got client: \(client != nil)")
            
            // Check for cancellation before updating state
            guard !Task.isCancelled else {
                print("🔥 ChatViewModel: Pre-warm cancelled before state update")
                return
            }
            
            // Update cached client and set up tool handler
            guard let self = self else { return }
            self.cachedClient = client
            self.isPrewarmingClient = false
            
            if let client = client {
                print("🔥 ChatViewModel: Pre-warm complete, client cached, state: \(client.connectionState)")
                
                // Only show session indicator on fresh connections, not when returning to an already-connected session
                // sessionWasResumed is nil until the first connect() call completes
                if let wasResumed = client.sessionWasResumed, !self.hasShownSessionIndicator {
                    self.sessionWasResumed = wasResumed
                    self.showSessionIndicator = true
                    self.hasShownSessionIndicator = true
                    // Hide indicator after 3 seconds
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        self.showSessionIndicator = false
                    }
                }
                
                // Set up tool approval handler now that we have the client
                if !self.isToolApprovalHandlerSetup {
                    self.setupToolApprovalHandlerSync(client: client)
                }

                // Consume any buffered agent response from cold-start push replay
                if let buffered = client.pendingBufferedResponse, !buffered.isEmpty {
                    print("🔄 [push-dbg] ChatViewModel consuming cold-start buffer: \(buffered.count) chars")
                    client.pendingBufferedResponse = nil
                    // Skip voice correction protocol responses — machine-readable JSON that
                    // must never appear in the chat UI.
                    let trimmed = buffered.trimmingCharacters(in: .whitespacesAndNewlines)
                    let isVoiceCorrectionResponse: Bool = {
                        guard trimmed.hasPrefix("{"),
                              let data = trimmed.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { return false }
                        return json["corrected_text"] != nil && json.count <= 2
                    }()
                    if !isVoiceCorrectionResponse {
                        let msg = Message(
                            text: buffered,
                            sender: .agent,
                            status: .sent,
                            type: .text
                        )
                        self.messages.append(msg)
                        self.updateConversation()
                        self.saveMessagesToDisk()
                    }
                }
            } else {
                print("🔥 ChatViewModel: Pre-warm complete but no client")
            }
        }
    }
    
    func filteredCommands(for query: String) -> [AvailableCommand] {
        guard !query.isEmpty else { return availableCommands }
        return availableCommands.filter { $0.name.lowercased().hasPrefix(query.lowercased()) }
    }

    /// Synchronous version of tool approval handler setup (call from MainActor)
    private func setupToolApprovalHandlerSync(client: ACPClientWrapper) {
        guard !isToolApprovalHandlerSetup else { return }
        isToolApprovalHandlerSetup = true

        client.onAvailableCommandsUpdate = { [weak self] commands in
            Task { @MainActor in self?.availableCommands = commands }
        }

        client.onRemoteUserMessage = { [weak self] text in
            // Voice correction protocol messages are machine-readable JSON sent to the LLM
            // for speech enhancement. They must never appear in the chat UI, even when the
            // bridge echoes them back via bridge/remoteUserMessage for multi-device sync.
            if text.contains("\"voice_correction_request\"") { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let msg = Message(
                    text: text,
                    sender: .user,
                    status: .sent,
                    type: .text
                )
                messages.append(msg)
                updateConversation()
                saveMessagesToDisk()
            }
        }

        print("💬 ChatViewModel: Setting up tool approval handler for agent \(agentId)")
        client.onToolApprovalRequest = { [weak self] toolCallId, title, command, permissions in
            Task { @MainActor in
                guard let self = self else { return }
                
                let commandText = command.map { "\n\n`\($0)`" } ?? ""
                
                // Convert permissions to PermissionOptionInfo
                let options = permissions.map { permission in
                    PermissionOptionInfo(
                        optionId: permission.optionId.value,
                        name: permission.name,
                        kind: permission.kind.rawValue
                    )
                }
                
                let approvalMessage = Message(
                    text: "⚠️ **Permission Required**\n\n\(title)\(commandText)",
                    sender: .agent,
                    status: .sent,
                    type: .toolApprovalRequest,
                    toolApproval: ToolApprovalInfo(
                        toolCallId: toolCallId,
                        title: title,
                        command: command,
                        options: options
                    )
                )
                
                if self.hasActiveApproval {
                    self.approvalQueue.append(approvalMessage)
                } else {
                    self.messages.append(approvalMessage)
                    self.updateConversation()
                }
            }
        }

        // On every (re)connect the inner AptoveClient is fresh — its pendingPermissions is
        // empty. Expire any approval cards that are still awaiting a decision so the user
        // doesn't see frozen buttons that silently fail when tapped.
        client.onReconnect = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var changed = false
                for i in messages.indices {
                    guard messages[i].type == .toolApprovalRequest,
                          let ta = messages[i].toolApproval,
                          ta.approved == nil else { continue }
                    messages[i] = Message(
                        id: messages[i].id,
                        text: messages[i].text,
                        sender: messages[i].sender,
                        timestamp: messages[i].timestamp,
                        status: .error,
                        type: messages[i].type,
                        toolApproval: ToolApprovalInfo(
                            toolCallId: ta.toolCallId,
                            title: ta.title,
                            command: ta.command,
                            approved: false,
                            options: ta.options
                        )
                    )
                    changed = true
                }
                if changed {
                    updateConversation()
                    saveMessagesToDisk()
                }
                approvalQueue.removeAll()
            }
        }
    }
    
    private func setupToolApprovalHandler() async {
        // Only set up once
        guard !isToolApprovalHandlerSetup else { return }
        
        // Use cached client or get it (should be pre-warmed by now)
        let client: ACPClientWrapper?
        if let cached = cachedClient {
            client = cached
            print("💬 ChatViewModel: Using pre-warmed client for tool approval handler")
        } else {
            print("💬 ChatViewModel: Client not pre-warmed, getting now...")
            client = await agentManager?.getClient(for: agentId)
        }
        
        guard let client = client else { return }
        
        setupToolApprovalHandlerSync(client: client)
    }
    
    func loadMessages() {
        guard let conversation = agentManager?.conversations[agentId] else {
            return
        }
        // Drop unanswered approval cards from previous sessions — their toolCallIds
        // are no longer valid and they would permanently block the approval queue.
        messages = conversation.messages.filter {
            $0.type != .toolApprovalRequest || $0.toolApproval?.approved != nil
        }
    }
    
    func sendMessage(_ text: String, images: [UIImage] = [], files: [FileAttachment] = []) async {
        print("📤 ChatViewModel.sendMessage: Starting...")
        isSending = true

        guard !isVoiceCorrectionPending else {
            print("⚠️ ChatViewModel: Blocked sendMessage — voice correction still in flight")
            isSending = false
            return
        }

        let imageDataList = images.compactMap { $0.jpegData(compressionQuality: 0.8) }
        let messageType: MessageType = text.hasPrefix("/") && !text.contains("\n") ? .slashCommand : .text
        let userMessage = Message(
            text: text,
            sender: .user,
            status: .sending,
            type: messageType,
            images: imageDataList.isEmpty ? nil : imageDataList,
            files: files.isEmpty ? nil : files
        )
        
        messages.append(userMessage)
        updateConversation()
        saveMessagesToDisk()

        // Use cached client if available (should be pre-warmed)
        let client: ACPClientWrapper?
        if let cached = cachedClient {
            print("📤 ChatViewModel.sendMessage: Using pre-warmed client")
            client = cached
        } else {
            print("📤 ChatViewModel.sendMessage: Client not pre-warmed, getting connected client now...")
            // Use getConnectedClient which handles session persistence
            client = await agentManager?.getConnectedClient(for: agentId)
            cachedClient = client
        }
        
        guard let client = client else {
            print("❌ ChatViewModel.sendMessage: No client available")
            updateMessageStatus(userMessage.id, to: .error)
            isSending = false
            return
        }
        
        // Set up tool approval handler lazily on first message
        if !isToolApprovalHandlerSetup {
            await setupToolApprovalHandler()
        }
        
        // Only connect if not already connected (getConnectedClient should handle this but double-check)
        if case .connected = client.connectionState {
            // Already connected, continue
        } else {
            // Need to connect - use AgentManager to handle session persistence
            if let manager = agentManager {
                let existingSessionId = manager.agents.first(where: { $0.id == agentId })?.activeSessionId
                await client.connect(existingSessionId: existingSessionId)
                
                // Update session info after connection
                if case .connected = client.connectionState {
                    manager.updateAgentSessionInfo(
                        agentId: agentId,
                        sessionId: client.sessionId,
                        supportsLoadSession: client.supportsLoadSession
                    )
                }
            } else {
                await client.connect()
            }
            
            // Check if connection was successful
            guard case .connected = client.connectionState else {
                let errorMsg = if case .error(let msg) = client.connectionState {
                    msg
                } else {
                    "Failed to connect to agent"
                }
                
                updateMessageStatus(userMessage.id, to: .error)
                
                let errorMessage = Message(
                    text: "Connection error: \(errorMsg)",
                    sender: .agent,
                    status: .error,
                    type: .text
                )
                
                messages.append(errorMessage)
                updateConversation()
                isSending = false
                return
            }
        }
        
        do {
            // Create agent message that will be updated incrementally
            let agentMessage = Message(
                text: "",
                sender: .agent,
                status: .sending,
                type: .text
            )
            messages.append(agentMessage)
            var agentMessageIndex = messages.count - 1
            var accumulatedText = "" // Track accumulated text separately
            var currentThoughtId: String? = nil // Track current thought message
            var currentToolId: String? = nil // Track current tool message
            var toolOutputMessages: [String: String] = [:] // Track tool output messages by toolCallId
            updateConversation()
            
            // Build content blocks: images → files → text
            var contentBlocks: [ContentBlock] = images.compactMap { img in
                guard let data = img.jpegData(compressionQuality: 0.8) else { return nil }
                return .image(ImageContent(data: data.base64EncodedString(), mimeType: "image/jpeg"))
            }
            for file in files {
                if file.mimeType.hasPrefix("text/"), let text = String(data: file.data, encoding: .utf8) {
                    contentBlocks.append(.resource(ResourceContent(resource: .text(TextResourceContents(
                        text: text,
                        uri: "file://\(file.name)",
                        mimeType: file.mimeType
                    )))))
                } else {
                    contentBlocks.append(.resource(ResourceContent(resource: .blob(BlobResourceContents(
                        blob: file.data.base64EncodedString(),
                        uri: "file://\(file.name)",
                        mimeType: file.mimeType
                    )))))
                }
            }
            if !text.isEmpty {
                contentBlocks.append(.text(TextContent(text: text)))
            }

            // Send message with streaming callbacks
            try await client.sendMessage(contentBlocks,
                onChunk: { chunk in
                    // Update agent message incrementally on main thread
                    Task { @MainActor in
                        // If non-thought messages were appended after our current slot (e.g. a tool
                        // approval card or tool status), seal the current bubble and start a new one.
                        // Thought messages appearing mid-stream do NOT split the bubble — they just
                        // sit below the streaming text while the same agent bubble keeps growing.
                        let trailingAreOnlyThoughts = self.messages.dropFirst(agentMessageIndex + 1)
                            .allSatisfy { $0.type == .thought }
                        if agentMessageIndex < self.messages.count - 1 && !accumulatedText.isEmpty && !trailingAreOnlyThoughts {
                            self.messages[agentMessageIndex] = Message(
                                id: self.messages[agentMessageIndex].id,
                                text: accumulatedText,
                                sender: .agent,
                                status: .sent,
                                type: .text
                            )
                            accumulatedText = ""
                            let newMsg = Message(text: "", sender: .agent, status: .sending, type: .text)
                            self.messages.append(newMsg)
                            agentMessageIndex = self.messages.count - 1
                            self.updateConversation()
                        }
                        accumulatedText += chunk
                        if agentMessageIndex < self.messages.count {
                            self.messages[agentMessageIndex] = Message(
                                id: self.messages[agentMessageIndex].id,
                                text: accumulatedText,
                                sender: .agent,
                                status: .sending,
                                type: .text
                            )
                            // Throttle: @Published messages already drives SwiftUI re-render.
                            // updateConversation() copies the array + sorts agents — expensive at
                            // streaming rate. Only call it periodically during active streaming.
                            let now = Date()
                            if now.timeIntervalSince(self.lastConversationUpdateTime) >= Self.streamingUpdateInterval {
                                self.updateConversation()
                                self.lastConversationUpdateTime = now
                            }
                        }
                    }
                },
                onThought: { thought in
                    // Display thought message
                    Task { @MainActor in
                        if let thinkingId = currentThoughtId,
                           let index = self.messages.firstIndex(where: { $0.id == thinkingId }) {
                            // Update existing thought message
                            self.messages[index] = Message(
                                id: thinkingId,
                                text: thought,
                                sender: .agent,
                                status: .sent,
                                type: .thought,
                                isThinking: true
                            )
                        } else {
                            // Create new thought message
                            let thinkingMsg = Message(
                                text: thought,
                                sender: .agent,
                                status: .sent,
                                type: .thought,
                                isThinking: true
                            )
                            self.messages.append(thinkingMsg)
                            currentThoughtId = thinkingMsg.id
                        }
                        self.updateConversation()
                    }
                },
                onToolCall: { toolTitle in
                    // Display tool status message
                    Task { @MainActor in
                        if let toolId = currentToolId,
                           let index = self.messages.firstIndex(where: { $0.id == toolId }) {
                            // Update existing tool message
                            self.messages[index] = Message(
                                id: toolId,
                                text: toolTitle,
                                sender: .agent,
                                status: .sent,
                                type: .toolStatus
                            )
                        } else {
                            // Create new tool message
                            let toolMsg = Message(
                                text: toolTitle,
                                sender: .agent,
                                status: .sent,
                                type: .toolStatus
                            )
                            self.messages.append(toolMsg)
                            currentToolId = toolMsg.id
                        }
                        self.updateConversation()
                    }
                },
                onToolUpdate: { toolCallId, content in
                    // Display or update tool output message
                    Task { @MainActor in
                        // Check if we already have a message for this tool
                        if let existingMsgId = toolOutputMessages[toolCallId],
                           let index = self.messages.firstIndex(where: { $0.id == existingMsgId }) {
                            // Update existing tool output message
                            let existingText = self.messages[index].text
                            self.messages[index] = Message(
                                id: existingMsgId,
                                text: existingText + "\n" + content,
                                sender: .agent,
                                status: .sent,
                                type: .toolStatus
                            )
                        } else {
                            // Create new tool output message
                            let toolOutputMsg = Message(
                                text: content,
                                sender: .agent,
                                status: .sent,
                                type: .toolStatus
                            )
                            self.messages.append(toolOutputMsg)
                            toolOutputMessages[toolCallId] = toolOutputMsg.id
                        }
                        self.updateConversation()
                    }
                },
                onComplete: { stopReason, errorMessage in
                    // Mark messages as complete
                    Task { @MainActor in
                        self.updateMessageStatus(userMessage.id, to: .sent)

                        if agentMessageIndex < self.messages.count {
                            // If agent message is empty, show the actual error or a fallback
                            let finalText: String
                            if !accumulatedText.isEmpty {
                                finalText = accumulatedText
                            } else if let errorMessage {
                                finalText = errorMessage
                            } else if stopReason == nil {
                                finalText = "Request failed"
                            } else {
                                finalText = "(No response received)"
                            }

                            self.messages[agentMessageIndex] = Message(
                                id: self.messages[agentMessageIndex].id,
                                text: finalText,
                                sender: .agent,
                                status: stopReason != nil ? .sent : .error,
                                type: .text
                            )
                            self.updateConversation()
                        }

                        // Stop the thought spinner now that the response is complete
                        if let thinkingId = currentThoughtId,
                           let thoughtIndex = self.messages.firstIndex(where: { $0.id == thinkingId }) {
                            self.messages[thoughtIndex].isThinking = false
                            self.updateConversation()
                        }

                        self.isSending = false
                        self.saveMessagesToDisk()
                    }
                }
            )
            
        } catch {
            updateMessageStatus(userMessage.id, to: .error)
            
            let errorMessage = Message(
                text: "Error: \(error.localizedDescription)",
                sender: .agent,
                status: .error,
                type: .text
            )
            
            messages.append(errorMessage)
            updateConversation()
            isSending = false
        }
        
        isSending = false
    }
    
    func sendVoiceCorrectionRequest(_ rawTranscript: String) async {
        let client: ACPClientWrapper?
        if let cached = cachedClient {
            client = cached
        } else {
            client = await agentManager?.getConnectedClient(for: agentId)
            cachedClient = client
        }

        // If there is no client, or the client is not currently connected,
        // degrade immediately to the raw transcript — do not attempt reconnect,
        // which would leave the user stuck in .processing for up to 30 s.
        guard let client, case .connected = client.connectionState else {
            voiceCorrectedText = rawTranscript
            return
        }

        isVoiceCorrectionPending = true

        print("🎤 [VoiceCorrection] Raw speech-to-text: \"\(rawTranscript)\"")

        // Per-language bridge instructions (hardcoded by design — sent to LLM, not user UI).
        // To add a language: add a case matching the 2-char language code prefix.
        let instructions: String
        switch String(voiceLanguage.prefix(2)) {
        case "ar": instructions = "صحّح أخطاء النسخ والترقيم والقواعد النحوية. أعد فقط JSON صالحًا بحقل واحد: {\"corrected_text\": \"...\"}"
        case "ca": instructions = "Corregeix els errors de transcripció, la puntuació i la gramàtica. Retorna NOMÉS JSON vàlid amb un únic camp: {\"corrected_text\": \"...\"}"
        case "cs": instructions = "Oprav chyby přepisu, interpunkci a gramatiku. Vrať POUZE platný JSON s jedním polem: {\"corrected_text\": \"...\"}"
        case "da": instructions = "Ret transskriptionsfejl, tegnsætning og grammatik. Returner KUN gyldig JSON med ét felt: {\"corrected_text\": \"...\"}"
        case "de": instructions = "Korrigiere Transkriptionsfehler, Interpunktion und Grammatik. Gib NUR gültiges JSON mit einem einzigen Feld zurück: {\"corrected_text\": \"...\"}"
        case "el": instructions = "Διόρθωσε τα σφάλματα μεταγραφής, στίξης και γραμματικής. Επέστρεψε ΜΟΝΟ έγκυρο JSON με ένα μόνο πεδίο: {\"corrected_text\": \"...\"}"
        case "es": instructions = "Corrige los errores de transcripción, puntuación y gramática. Devuelve SOLO JSON válido con un único campo: {\"corrected_text\": \"...\"}"
        case "fi": instructions = "Korjaa transkriptiovirheet, välimerkit ja kielioppi. Palauta VAIN kelvollinen JSON yhdellä kentällä: {\"corrected_text\": \"...\"}"
        case "fr": instructions = "Corrige les erreurs de transcription, la ponctuation et la grammaire. Retourne UNIQUEMENT du JSON valide avec un seul champ : {\"corrected_text\": \"...\"}"
        case "he": instructions = "תקן שגיאות תמלול, פיסוק ודקדוק. החזר רק JSON תקני עם שדה יחיד: {\"corrected_text\": \"...\"}"
        case "hi": instructions = "ट्रांसक्रिप्शन त्रुटियाँ, विराम चिह्न और व्याकरण ठीक करें। केवल एक फ़ील्ड के साथ वैध JSON लौटाएँ: {\"corrected_text\": \"...\"}"
        case "hr": instructions = "Ispravi greške transkripcije, interpunkciju i gramatiku. Vrati SAMO valjani JSON s jednim poljem: {\"corrected_text\": \"...\"}"
        case "hu": instructions = "Javítsd az átírási hibákat, írásjeleket és nyelvtant. Csak érvényes JSON-t adj vissza egyetlen mezővel: {\"corrected_text\": \"...\"}"
        case "id": instructions = "Perbaiki kesalahan transkripsi, tanda baca, dan tata bahasa. Kembalikan HANYA JSON yang valid dengan satu bidang: {\"corrected_text\": \"...\"}"
        case "it": instructions = "Correggi gli errori di trascrizione, punteggiatura e grammatica. Restituisci SOLO JSON valido con un unico campo: {\"corrected_text\": \"...\"}"
        case "ja": instructions = "文字起こしのエラー、句読点、文法を修正してください。単一フィールドの有効なJSONのみを返してください：{\"corrected_text\": \"...\"}"
        case "ko": instructions = "전사 오류, 구두점, 문법을 수정하세요. 단일 필드가 있는 유효한 JSON만 반환하세요: {\"corrected_text\": \"...\"}"
        case "ms": instructions = "Betulkan ralat transkripsi, tanda baca, dan tatabahasa. Kembalikan HANYA JSON yang sah dengan satu medan: {\"corrected_text\": \"...\"}"
        case "nb", "no": instructions = "Rett transkripsjonsfeil, tegnsetting og grammatikk. Returner KUN gyldig JSON med ett felt: {\"corrected_text\": \"...\"}"
        case "nl": instructions = "Corrigeer transcriptiefouten, interpunctie en grammatica. Geef ALLEEN geldige JSON terug met één veld: {\"corrected_text\": \"...\"}"
        case "pl": instructions = "Popraw błędy transkrypcji, interpunkcję i gramatykę. Zwróć TYLKO poprawny JSON z jednym polem: {\"corrected_text\": \"...\"}"
        case "pt": instructions = "Corrija erros de transcrição, pontuação e gramática. Retorne SOMENTE JSON válido com um único campo: {\"corrected_text\": \"...\"}"
        case "ro": instructions = "Corectează erorile de transcriere, punctuația și gramatica. Returnează NUMAI JSON valid cu un singur câmp: {\"corrected_text\": \"...\"}"
        case "ru": instructions = "Исправь ошибки транскрипции, пунктуацию и грамматику. Верни ТОЛЬКО корректный JSON с одним полем: {\"corrected_text\": \"...\"}"
        case "sk": instructions = "Oprav chyby prepisu, interpunkciu a gramatiku. Vráť IBA platný JSON s jedným poľom: {\"corrected_text\": \"...\"}"
        case "sv": instructions = "Rätta transkriptionsfel, skiljetecken och grammatik. Returnera BARA giltig JSON med ett enda fält: {\"corrected_text\": \"...\"}"
        case "ta": instructions = "படியெடுப்பு பிழைகள், நிறுத்தற்குறிகள் மற்றும் இலக்கணத்தை சரிசெய்யுங்கள். ஒரே ஒரு புலத்துடன் சரியான JSONஐ மட்டுமே திருப்பி அனுப்புங்கள்: {\"corrected_text\": \"...\"}"
        case "th": instructions = "แก้ไขข้อผิดพลาดในการถอดเสียง เครื่องหมายวรรคตอน และไวยากรณ์ ส่งคืนเฉพาะ JSON ที่ถูกต้องพร้อมฟิลด์เดียว: {\"corrected_text\": \"...\"}"
        case "tr": instructions = "Transkripsiyon hatalarını, noktalama işaretlerini ve dil bilgisini düzelt. Yalnızca tek bir alanlı geçerli JSON döndür: {\"corrected_text\": \"...\"}"
        case "uk": instructions = "Виправ помилки транскрипції, пунктуацію та граматику. Поверни ЛИШЕ коректний JSON з одним полем: {\"corrected_text\": \"...\"}"
        case "vi": instructions = "Sửa lỗi phiên âm, dấu câu và ngữ pháp. Chỉ trả về JSON hợp lệ với một trường duy nhất: {\"corrected_text\": \"...\"}"
        case "zh", "wu": instructions = "修正转录错误、标点符号和语法。仅返回包含单个字段的有效JSON：{\"corrected_text\": \"...\"}"
        default: instructions = "Fix transcription errors, punctuation, and grammar. Return ONLY valid JSON with a single field: {\"corrected_text\": \"...\"}"
        }

        let correctionJson = """
        {
            "type": "voice_correction_request",
            "version": "1.0",
            "language": \(encodeJsonString(voiceLanguage)),
            "instructions": \(encodeJsonString(instructions)),
            "raw_transcript": \(encodeJsonString(rawTranscript))
        }
        """

        var accumulated = ""

        // sendMessage() fires an internal detached Task and returns immediately,
        // so a plain `try await` exits before any chunks arrive.
        // Use a continuation gated on onComplete to actually wait for the full response.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                do {
                    try await client.sendMessage(
                        correctionJson,
                        onChunk: { chunk in accumulated += chunk },
                        onThought: nil,
                        onToolCall: nil,
                        onToolUpdate: nil,
                        onComplete: { _, _ in cont.resume() }
                    )
                } catch {
                    // sendMessage threw before spawning the prompt task (e.g. no session)
                    print("❌ [VoiceCorrection] sendMessage threw: \(error.localizedDescription)")
                    cont.resume()
                }
            }
        }

        if let corrected = parseCorrectedText(from: accumulated) {
            print("🤖 [VoiceCorrection] Agent corrected to: \"\(corrected)\"")
            voiceCorrectedText = corrected
        } else {
            print("⚠️ [VoiceCorrection] Agent parse failed, using raw transcript. Agent response: \"\(accumulated)\"")
            voiceCorrectedText = rawTranscript
        }

        isVoiceCorrectionPending = false
    }

    private func encodeJsonString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private func parseCorrectedText(from response: String) -> String? {
        // Try candidates in order: raw response, JSON stripped from markdown code fences,
        // and a best-effort substring between the first { and last }.
        let candidates: [String] = [
            response,
            extractJsonFromCodeFence(response),
            extractJsonBraces(response)
        ].compactMap { $0 }

        for candidate in candidates {
            if let data = candidate.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let corrected = obj["corrected_text"] as? String,
               !corrected.isEmpty {
                return corrected
            }
        }
        return nil
    }

    private func extractJsonFromCodeFence(_ text: String) -> String? {
        guard let regex = Self.codeFenceRegex,
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func extractJsonBraces(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") ,
              start <= end else { return nil }
        return String(text[start...end])
    }

    private func updateMessageStatus(_ messageId: String, to status: MessageStatus) {
        if let index = messages.firstIndex(where: { $0.id == messageId }) {
            let msg = messages[index]
            messages[index] = Message(
                id: msg.id,
                text: msg.text,
                sender: msg.sender,
                timestamp: msg.timestamp,
                status: status,
                type: msg.type,
                toolApproval: msg.toolApproval,
                images: msg.images,
                files: msg.files
            )
            updateConversation()
        }
    }
    
    func approveTool(messageId: String, optionId: String = "allow_once") async {
        defer { showNextQueuedApproval() }

        guard let message = messages.first(where: { $0.id == messageId }),
              let toolApproval = message.toolApproval else { return }
        guard let client = cachedClient else { return }

        do {
            try await client.approveTool(toolCallId: toolApproval.toolCallId, optionId: optionId)

            if let index = messages.firstIndex(where: { $0.id == messageId }) {
                let updatedApproval = ToolApprovalInfo(
                    toolCallId: toolApproval.toolCallId,
                    title: toolApproval.title,
                    command: toolApproval.command,
                    approved: true,
                    options: toolApproval.options
                )
                messages[index] = Message(
                    id: message.id,
                    text: message.text,
                    sender: message.sender,
                    timestamp: message.timestamp,
                    status: .sent,
                    type: message.type,
                    toolApproval: updatedApproval
                )
                updateConversation()
                saveMessagesToDisk()
            }
        } catch {
            // The pending approval RPC is gone (connection was reset and AptoveClient recreated).
            // Mark the card expired so the frozen buttons are removed.
            if let index = messages.firstIndex(where: { $0.id == messageId }) {
                let expiredApproval = ToolApprovalInfo(
                    toolCallId: toolApproval.toolCallId,
                    title: toolApproval.title,
                    command: toolApproval.command,
                    approved: false,
                    options: toolApproval.options
                )
                messages[index] = Message(
                    id: message.id,
                    text: message.text,
                    sender: message.sender,
                    timestamp: message.timestamp,
                    status: .error,
                    type: message.type,
                    toolApproval: expiredApproval
                )
                updateConversation()
                saveMessagesToDisk()
            }
            print("Tool approval expired after reconnect: \(error)")
        }
    }

    func rejectTool(messageId: String) async {
        defer { showNextQueuedApproval() }

        guard let message = messages.first(where: { $0.id == messageId }),
              let toolApproval = message.toolApproval else { return }
        guard let client = cachedClient else { return }

        do {
            try await client.rejectTool(toolCallId: toolApproval.toolCallId)

            if let index = messages.firstIndex(where: { $0.id == messageId }) {
                let updatedApproval = ToolApprovalInfo(
                    toolCallId: toolApproval.toolCallId,
                    title: toolApproval.title,
                    command: toolApproval.command,
                    approved: false,
                    options: toolApproval.options
                )
                messages[index] = Message(
                    id: message.id,
                    text: message.text,
                    sender: message.sender,
                    timestamp: message.timestamp,
                    status: .sent,
                    type: message.type,
                    toolApproval: updatedApproval
                )
                updateConversation()
                saveMessagesToDisk()
            }
        } catch {
            // The pending approval RPC is gone (connection was reset and AptoveClient recreated).
            // Mark the card expired so the frozen buttons are removed.
            if let index = messages.firstIndex(where: { $0.id == messageId }) {
                let expiredApproval = ToolApprovalInfo(
                    toolCallId: toolApproval.toolCallId,
                    title: toolApproval.title,
                    command: toolApproval.command,
                    approved: false,
                    options: toolApproval.options
                )
                messages[index] = Message(
                    id: message.id,
                    text: message.text,
                    sender: message.sender,
                    timestamp: message.timestamp,
                    status: .error,
                    type: message.type,
                    toolApproval: expiredApproval
                )
                updateConversation()
                saveMessagesToDisk()
            }
            print("Tool rejection expired after reconnect: \(error)")
        }
    }
    
    private var hasActiveApproval: Bool {
        messages.contains { $0.type == .toolApprovalRequest && $0.toolApproval?.approved == nil }
    }

    private func showNextQueuedApproval() {
        guard !approvalQueue.isEmpty else { return }
        let next = approvalQueue.removeFirst()
        messages.append(next)
        updateConversation()
    }

    private func updateConversation() {
        guard let manager = agentManager else { return }

        let previousAgentCount = manager.conversations[agentId]?.messages
            .filter { $0.sender == .agent }.count ?? 0

        var conversation = manager.conversations[agentId] ?? Conversation(agentId: agentId)
        conversation.messages = messages
        conversation.lastActivity = Date()

        manager.conversations[agentId] = conversation
        manager.sortAgents()

        let newAgentCount = messages.filter { $0.sender == .agent }.count
        let delta = newAgentCount - previousAgentCount
        if delta > 0 {
            manager.incrementUnreadCount(agentId: agentId, by: delta)
        }
    }

    private func saveMessagesToDisk() {
        guard let manager = agentManager,
              let agentEntity = manager.repository.getAgentEntity(agentId: agentId)
        else { return }
        manager.messageRepository.saveMessages(messages, agentId: agentId, agent: agentEntity)
    }
}

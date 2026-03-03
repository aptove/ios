import Foundation
import AVFoundation
import Speech

enum RecordingState {
    case idle
    case requestingPermission
    case recording
    case processing
    case error(String)
}

@MainActor
class VoiceInputViewModel: ObservableObject {
    @Published var recordingState: RecordingState = .idle

    var onTranscriptReady: ((String) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale.current)

    func startRecording() {
        recordingState = .requestingPermission

        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            Task { @MainActor in
                guard let self = self else { return }
                switch authStatus {
                case .authorized:
                    self.requestMicrophonePermission()
                default:
                    self.recordingState = .error("Speech recognition permission denied")
                }
            }
        }
    }

    private func requestMicrophonePermission() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self = self else { return }
                if granted {
                    self.beginRecording()
                } else {
                    self.recordingState = .error("Microphone permission denied")
                }
            }
        }
    }

    private func beginRecording() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAudioSessionInterruption),
                name: AVAudioSession.interruptionNotification,
                object: audioSession
            )

            let engine = AVAudioEngine()
            audioEngine = engine

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            recognitionRequest = request

            let inputNode = engine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                request.append(buffer)
            }

            engine.prepare()
            try engine.start()

            guard let recognizer = speechRecognizer, recognizer.isAvailable else {
                recordingState = .error("Speech recognizer not available")
                return
            }

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self = self else { return }

                    if let error = error {
                        // Ignore cancellation errors (happen when stopRecording is called)
                        let nsError = error as NSError
                        if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                            return
                        }
                        self.stopEngine()
                        self.recordingState = .error(error.localizedDescription)
                        return
                    }

                    if let result = result, result.isFinal {
                        let transcript = result.bestTranscription.formattedString
                        self.stopEngine()
                        self.recordingState = .idle
                        self.onTranscriptReady?(transcript)
                    }
                }
            }

            recordingState = .recording
        } catch {
            stopEngine()
            recordingState = .error(error.localizedDescription)
        }
    }

    func stopRecording() {
        guard case .recording = recordingState else { return }
        recordingState = .processing
        recognitionRequest?.endAudio()
        // recognitionTask will fire isFinal after endAudio
    }

    private func stopEngine() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    @objc private func handleAudioSessionInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        if type == .began {
            Task { @MainActor in
                self.stopEngine()
                self.recordingState = .error("Recording interrupted")
            }
        }
    }
}

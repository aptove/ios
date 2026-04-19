import Foundation
import AVFoundation
import Speech

enum RecordingState {
    case idle
    case requestingPermission
    case recording
    case paused
    case processing
    case error(String)

    var isActiveRecording: Bool {
        switch self {
        case .recording, .paused: return true
        default: return false
        }
    }
}

@MainActor
class VoiceInputViewModel: ObservableObject {
    @Published var recordingState: RecordingState = .idle
    @Published var waveformSamples: [Float] = Array(repeating: 0, count: 40)
    @Published var elapsedSeconds: Int = 0

    var onTranscriptReady: ((String) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale.current)

    func updateLocale(_ identifier: String) {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier))
    }
    private var recordingTimer: Timer?

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
        elapsedSeconds = 0
        waveformSamples = Array(repeating: 0, count: 40)
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.elapsedSeconds += 1 }
        }
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
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                request.append(buffer)
                guard let channelData = buffer.floatChannelData?[0] else { return }
                let frameLen = Int(buffer.frameLength)
                let rms = sqrt((0..<frameLen).reduce(0.0) { $0 + channelData[$1] * channelData[$1] } / Float(frameLen))
                let level = min(rms * 15, 1.0)
                DispatchQueue.main.async {
                    self?.waveformSamples.removeFirst()
                    self?.waveformSamples.append(level)
                }
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
                        // Stay in .processing — caller resets to .idle when AI response is ready
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

    func pauseRecording() {
        guard case .recording = recordingState else { return }
        audioEngine?.pause()
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingState = .paused
    }

    func resumeRecording() {
        guard case .paused = recordingState else { return }
        do {
            try audioEngine?.start()
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                DispatchQueue.main.async { self?.elapsedSeconds += 1 }
            }
            recordingState = .recording
        } catch {
            stopEngine()
            recordingState = .error(error.localizedDescription)
        }
    }

    func stopRecording() {
        switch recordingState {
        case .recording, .paused:
            recordingState = .processing
            recognitionRequest?.endAudio()
            // recognitionTask will fire isFinal after endAudio
        default:
            return
        }
    }

    func cancelRecording() {
        stopEngine()
        recordingState = .idle
    }

    private func stopEngine() {
        recordingTimer?.invalidate()
        recordingTimer = nil
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

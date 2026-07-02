import AVFoundation
import Foundation
import Observation
import OSLog
import Speech

@MainActor
@Observable
final class VoiceInputService {
    nonisolated static let unavailableMessage = "Voice recording unavailable here. Type the transcript instead."

    private enum RecordingState: Equatable {
        case idle
        case starting
        case recording

        var logLabel: String {
            switch self {
            case .idle: "idle"
            case .starting: "starting"
            case .recording: "recording"
            }
        }
    }

    var transcript = ""
    var statusMessage: String
    var recordingCapability: VoiceRecordingCapability

    private var state: RecordingState = .idle

    var isRecording: Bool { state == .recording }

    // Speech recognizer and audio engine each open XPC connections to system
    // services; allocating them lazily keeps view construction from stalling
    // the main thread when the composer first appears.
    @ObservationIgnored
    private lazy var recognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer()
    @ObservationIgnored
    private lazy var audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var hasInstalledTap = false

    /// True while any audio or recognition resources are live, without touching
    /// the lazy audio engine (so an early stop never allocates it).
    private var hasActiveAudioWork: Bool {
        state != .idle || request != nil || task != nil || hasInstalledTap
    }

    init(recordingCapability: VoiceRecordingCapability? = nil) {
        let capability = recordingCapability ?? Self.defaultRecordingCapability()
        self.recordingCapability = capability
        self.statusMessage = capability.message
        AppLog.voice.debug("VoiceInputService initialized capability=\(capability.logLabel, privacy: .public)")
    }

    var canRecordAudio: Bool {
        recordingCapability.isSupported
    }

    var recordButtonTitle: String {
        if isRecording {
            return "Stop"
        }
        return canRecordAudio ? "Start Recording" : "Voice Unavailable"
    }

    var recordButtonSystemImage: String {
        if isRecording {
            return "stop.circle.fill"
        }
        return canRecordAudio ? "mic.circle.fill" : "mic.slash.fill"
    }

    func startRecording() async {
        guard state == .idle else {
            AppLog.voice.debug("Voice recording start ignored state=\(self.state.logLabel, privacy: .public)")
            return
        }
        state = .starting

        // Any early exit below leaves the service idle again; only the success
        // path flips this to true and locks in the .recording state.
        var didStartRecording = false
        defer {
            if !didStartRecording, state == .starting {
                state = .idle
            }
        }

        AppLog.voice.info("Voice recording start requested")
        refreshRecordingCapability()
        guard recordingCapability.isSupported else {
            statusMessage = recordingCapability.message
            AppLog.voice.info("Voice recording unavailable reason=\(self.statusMessage, privacy: .public)")
            return
        }

        let speechStatus: SFSpeechRecognizerAuthorizationStatus
        do {
            speechStatus = try await speechAuthorizationStatus()
        } catch {
            statusMessage = Self.friendlyMessage(for: error)
            recordingCapability = .unavailable(statusMessage)
            AppLog.voice.error("Speech authorization preflight failed error=\(error.localizedDescription, privacy: .public)")
            return
        }

        guard speechStatus == .authorized else {
            statusMessage = Self.statusMessage(for: speechStatus)
            AppLog.voice.warning("Speech authorization denied status=\(String(describing: speechStatus), privacy: .public)")
            return
        }

        let micGranted = await requestMicrophonePermission()
        guard micGranted else {
            statusMessage = "Microphone permission is required."
            AppLog.voice.warning("Microphone permission denied")
            return
        }

        do {
            try await Self.activateAudioSession()
            try validateAudioRoute()
            try startAudioRecognition()
            state = .recording
            didStartRecording = true
            statusMessage = "Listening..."
            AppLog.voice.info("Voice recording started")
        } catch {
            statusMessage = Self.friendlyMessage(for: error)
            AppLog.voice.error("Voice recording failed error=\(error.localizedDescription, privacy: .public)")
            if Self.isUnavailableAudioError(error) {
                recordingCapability = .unavailable(statusMessage)
            }
            stopRecording()
        }
    }

    func stopRecording() {
        guard hasActiveAudioWork else { return }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        state = .idle
        statusMessage = transcript.isEmpty ? recordingCapability.message : "Transcript captured"
        Task {
            await Self.deactivateAudioSession()
        }
        AppLog.voice.info("Voice recording stopped transcriptCharacters=\(self.transcript.count, privacy: .public)")
    }

    func reset() {
        stopRecording()
        transcript = ""
        statusMessage = recordingCapability.message
        AppLog.voice.debug("Voice transcript reset")
    }

    func refreshRecordingCapability() {
        let previous = recordingCapability
        recordingCapability = currentRecordingCapability()
        if !recordingCapability.isSupported {
            statusMessage = recordingCapability.message
        }
        if previous != recordingCapability {
            AppLog.voice.info("Voice recording capability changed from=\(previous.logLabel, privacy: .public) to=\(self.recordingCapability.logLabel, privacy: .public)")
        }
    }

    /// Full capability check including recognizer availability. Reuses the
    /// stored recognizer instead of allocating throwaway instances per call.
    private func currentRecordingCapability() -> VoiceRecordingCapability {
        #if targetEnvironment(simulator)
        return .unavailable(Self.unavailableMessage)
        #else
        if let configurationError = Self.speechRecognitionConfigurationError() {
            return .unavailable(configurationError.errorDescription ?? Self.unavailableMessage)
        }
        guard recognizer != nil else {
            return .unavailable("Speech recognition is unavailable. Type the transcript instead.")
        }
        return .supported
        #endif
    }

    private func speechAuthorizationStatus() async throws -> SFSpeechRecognizerAuthorizationStatus {
        try Self.validateSpeechRecognitionConfiguration()

        let currentStatus = SFSpeechRecognizer.authorizationStatus()
        guard currentStatus == .notDetermined else {
            AppLog.voice.debug("Speech authorization already determined status=\(String(describing: currentStatus), privacy: .public)")
            return currentStatus
        }

        AppLog.voice.info("Requesting speech authorization")
        return await requestSpeechAuthorization()
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Configuring and activating the audio session performs blocking XPC calls
    /// to the audio server (often >1s on first use), so it runs on the concurrent
    /// executor instead of the main actor.
    @concurrent
    private static func activateAudioSession() async throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        AppLog.voice.debug("Audio session configured category=record mode=measurement")
    }

    @concurrent
    private static func deactivateAudioSession() async {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func validateAudioRoute() throws {
        #if targetEnvironment(simulator)
        AppLog.voice.info("Audio route unavailable target=simulator")
        throw VoiceInputError.recordingUnavailable(Self.unavailableMessage)
        #else
        let audioSession = AVAudioSession.sharedInstance()
        let hasAvailableInput = !(audioSession.availableInputs ?? []).isEmpty
        guard audioSession.inputNumberOfChannels > 0 || hasAvailableInput else {
            AppLog.voice.warning("Audio route has no input channels availableInputs=\(audioSession.availableInputs?.count ?? 0, privacy: .public)")
            throw VoiceInputError.noAudioInput
        }
        AppLog.voice.debug("Audio route valid channels=\(audioSession.inputNumberOfChannels, privacy: .public) availableInputs=\(audioSession.availableInputs?.count ?? 0, privacy: .public)")
        #endif
    }

    private func startAudioRecognition() throws {
        guard let recognizer else {
            AppLog.voice.warning("No speech recognizer available")
            throw VoiceInputError.noSpeechRecognizer
        }
        guard recognizer.isAvailable else {
            AppLog.voice.warning("Speech recognizer unavailable locale=\(recognizer.locale.identifier, privacy: .public)")
            throw VoiceInputError.speechRecognizerUnavailable
        }

        task?.cancel()
        task = nil

        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        self.request = recognitionRequest

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceInputError.invalidInputFormat
        }

        if hasInstalledTap {
            inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        // The tap block runs on the realtime audio thread, so it must not inherit
        // this class's MainActor isolation (the inherited isolation traps with
        // EXC_BREAKPOINT at runtime). Appending buffers to the request from the
        // tap is the documented, thread-safe usage.
        nonisolated(unsafe) let tapRequest = recognitionRequest
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            tapRequest.append(buffer)
        }
        hasInstalledTap = true

        audioEngine.prepare()
        try audioEngine.start()
        AppLog.voice.debug("Audio engine started sampleRate=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public)")

        // The result handler may be delivered off the main thread; extract the
        // Sendable pieces here and hop to the main actor for all state updates.
        task = recognizer.recognitionTask(with: recognitionRequest) { @Sendable [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorDescription = error?.localizedDescription

            Task { @MainActor in
                guard let self else { return }
                if let transcript {
                    self.transcript = transcript
                    if isFinal {
                        AppLog.voice.info("Speech recognition produced final transcript characters=\(transcript.count, privacy: .public)")
                    }
                }
                if let errorDescription {
                    AppLog.voice.error("Speech recognition task ended error=\(errorDescription, privacy: .public)")
                }
                if errorDescription != nil || isFinal {
                    self.stopRecording()
                }
            }
        }
    }
}

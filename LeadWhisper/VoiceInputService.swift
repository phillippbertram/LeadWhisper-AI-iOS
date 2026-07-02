import AVFoundation
import Foundation
import Observation
import OSLog
import Speech

enum VoiceRecordingCapability: Equatable, Sendable {
    case supported
    case unavailable(String)

    var isSupported: Bool {
        if case .supported = self {
            return true
        }
        return false
    }

    var message: String {
        switch self {
        case .supported:
            "Ready"
        case .unavailable(let reason):
            reason
        }
    }

    var logLabel: String {
        switch self {
        case .supported:
            "supported"
        case .unavailable:
            "unavailable"
        }
    }
}

@MainActor
@Observable
final class VoiceInputService {
    nonisolated static let unavailableMessage = "Voice recording unavailable here. Type the transcript instead."

    var transcript = ""
    var isRecording = false
    var statusMessage: String
    var recordingCapability: VoiceRecordingCapability

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var hasInstalledTap = false

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
        guard !isRecording else { return }

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
            try configureAudio()
            try validateAudioRoute()
            try startAudioRecognition()
            isRecording = true
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
        guard isRecording || audioEngine.isRunning || request != nil || task != nil || hasInstalledTap else { return }
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
        isRecording = false
        statusMessage = transcript.isEmpty ? recordingCapability.message : "Transcript captured"
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
        recordingCapability = Self.defaultRecordingCapability()
        if !recordingCapability.isSupported {
            statusMessage = recordingCapability.message
        }
        if previous != recordingCapability {
            AppLog.voice.info("Voice recording capability changed from=\(previous.logLabel, privacy: .public) to=\(self.recordingCapability.logLabel, privacy: .public)")
        }
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

    private func configureAudio() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        AppLog.voice.debug("Audio session configured category=record mode=measurement")
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
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            recognitionRequest.append(buffer)
        }
        hasInstalledTap = true

        audioEngine.prepare()
        try audioEngine.start()
        AppLog.voice.debug("Audio engine started sampleRate=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public)")

        task = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                if let result {
                    self?.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        AppLog.voice.info("Speech recognition produced final transcript characters=\(result.bestTranscription.formattedString.count, privacy: .public)")
                    }
                }
                if let error {
                    AppLog.voice.error("Speech recognition task ended error=\(error.localizedDescription, privacy: .public)")
                }
                if error != nil || result?.isFinal == true {
                    self?.stopRecording()
                }
            }
        }
    }

    static func defaultRecordingCapability() -> VoiceRecordingCapability {
        #if targetEnvironment(simulator)
        .unavailable(unavailableMessage)
        #else
        if let configurationError = speechRecognitionConfigurationError() {
            return .unavailable(configurationError.errorDescription ?? unavailableMessage)
        }
        if SFSpeechRecognizer(locale: Locale(identifier: "en-US")) == nil, SFSpeechRecognizer() == nil {
            return .unavailable("Speech recognition is unavailable. Type the transcript instead.")
        }
        return .supported
        #endif
    }

    static func friendlyMessage(for error: Error) -> String {
        if let error = error as? VoiceInputError {
            return error.errorDescription ?? unavailableMessage
        }
        return error.localizedDescription
    }

    static func statusMessage(for status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            "Speech recognition is authorized."
        case .denied:
            "Speech recognition permission is denied. Type the transcript instead."
        case .restricted:
            "Speech recognition is restricted on this device. Type the transcript instead."
        case .notDetermined:
            "Speech recognition permission is required."
        @unknown default:
            "Speech recognition is unavailable. Type the transcript instead."
        }
    }

    static func isUnavailableAudioError(_ error: Error) -> Bool {
        guard let error = error as? VoiceInputError else { return false }
        switch error {
        case .recordingUnavailable, .noAudioInput, .invalidInputFormat, .noSpeechRecognizer, .speechRecognizerUnavailable, .missingUsageDescription:
            return true
        }
    }

    static func validateSpeechRecognitionConfiguration() throws {
        if let error = speechRecognitionConfigurationError() {
            throw error
        }
    }

    private static func speechRecognitionConfigurationError() -> VoiceInputError? {
        guard hasUsageDescription("NSSpeechRecognitionUsageDescription") else {
            return .missingUsageDescription("NSSpeechRecognitionUsageDescription")
        }

        guard hasUsageDescription("NSMicrophoneUsageDescription") else {
            return .missingUsageDescription("NSMicrophoneUsageDescription")
        }

        return nil
    }

    private static func hasUsageDescription(_ key: String) -> Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            AppLog.voice.error("Missing Info.plist usage description key=\(key, privacy: .public)")
            return false
        }
        return value.nilIfBlank != nil
    }

}

enum VoiceInputError: LocalizedError {
    case recordingUnavailable(String)
    case noAudioInput
    case invalidInputFormat
    case noSpeechRecognizer
    case speechRecognizerUnavailable
    case missingUsageDescription(String)

    var errorDescription: String? {
        switch self {
        case .recordingUnavailable(let reason):
            reason
        case .noAudioInput:
            VoiceInputService.unavailableMessage
        case .invalidInputFormat:
            VoiceInputService.unavailableMessage
        case .noSpeechRecognizer:
            "Speech recognition is unavailable. Type the transcript instead."
        case .speechRecognizerUnavailable:
            "Speech recognition is temporarily unavailable. Type the transcript instead."
        case .missingUsageDescription(let key):
            "Missing \(key). Type the transcript instead."
        }
    }
}

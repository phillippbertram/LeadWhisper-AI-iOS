import AVFoundation
import CoreMedia
import Darwin
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

    // The audio engine opens XPC connections to system services; allocating it
    // lazily keeps view construction from stalling the main thread.
    @ObservationIgnored
    private lazy var audioEngine = AVAudioEngine()
    @ObservationIgnored
    private var analyzer: SpeechAnalyzer?
    @ObservationIgnored
    private var transcriber: SpeechTranscriber?
    @ObservationIgnored
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored
    private var analysisTask: Task<Void, Never>?
    @ObservationIgnored
    private var resultTask: Task<Void, Never>?
    @ObservationIgnored
    private var transcriptionSegments: [TranscriptionSegment] = []
    private var hasInstalledTap = false

    /// True while any audio or recognition resources are live, without touching
    /// the lazy audio engine (so an early stop never allocates it).
    private var hasActiveAudioWork: Bool {
        state != .idle || inputContinuation != nil || analysisTask != nil || resultTask != nil || hasInstalledTap
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
            let transcriber = try await makeTranscriber()
            try await prepareSpeechAssets(for: transcriber)
            try await Self.activateAudioSession()
            try validateAudioRoute()
            try await startAudioAnalysis(transcriber: transcriber)
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
        inputContinuation?.finish()
        inputContinuation = nil
        analysisTask?.cancel()
        resultTask?.cancel()
        analysisTask = nil
        resultTask = nil
        transcriber = nil
        let analyzerToCancel = analyzer
        analyzer = nil
        transcriptionSegments = []
        state = .idle
        statusMessage = transcript.isEmpty ? recordingCapability.message : "Transcript captured"
        Task {
            await analyzerToCancel?.cancelAndFinishNow()
            await Self.deactivateAudioSession()
        }
        AppLog.voice.info("Voice recording stopped transcriptCharacters=\(self.transcript.count, privacy: .public)")
    }

    func reset() {
        stopRecording()
        transcript = ""
        transcriptionSegments = []
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

    /// Full capability check including transcriber availability.
    private func currentRecordingCapability() -> VoiceRecordingCapability {
        #if targetEnvironment(simulator)
        return .unavailable(Self.unavailableMessage)
        #else
        if let configurationError = Self.speechRecognitionConfigurationError() {
            return .unavailable(configurationError.errorDescription ?? Self.unavailableMessage)
        }
        guard SpeechTranscriber.isAvailable else {
            return .unavailable("Speech transcription is unavailable. Type the transcript instead.")
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
        await AVAudioApplication.requestRecordPermission()
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

    private func makeTranscriber() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else {
            AppLog.voice.warning("SpeechTranscriber unavailable")
            throw VoiceInputError.speechRecognizerUnavailable
        }

        let preferredLocale = Locale.current
        let locale: Locale?
        if let supportedPreferredLocale = await SpeechTranscriber.supportedLocale(equivalentTo: preferredLocale) {
            locale = supportedPreferredLocale
        } else {
            locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        }

        guard let locale else {
            AppLog.voice.warning("No supported speech transcription locale for preferred=\(preferredLocale.identifier, privacy: .public)")
            throw VoiceInputError.speechRecognizerUnavailable
        }

        AppLog.voice.debug("SpeechTranscriber selected locale=\(locale.identifier, privacy: .public)")
        return SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }

    private func prepareSpeechAssets(for transcriber: SpeechTranscriber) async throws {
        let modules: [any SpeechModule] = [transcriber]
        let status = await AssetInventory.status(forModules: modules)
        AppLog.voice.debug("Speech asset status=\(String(describing: status), privacy: .public)")

        switch status {
        case .installed:
            return
        case .supported, .downloading:
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
                return
            }
            statusMessage = "Preparing on-device speech model..."
            try await request.downloadAndInstall()
            AppLog.voice.info("Speech assets installed for transcription")
        case .unsupported:
            throw VoiceInputError.speechRecognizerUnavailable
        @unknown default:
            throw VoiceInputError.speechRecognizerUnavailable
        }
    }

    private func startAudioAnalysis(transcriber: SpeechTranscriber) async throws {
        analysisTask?.cancel()
        resultTask?.cancel()
        analysisTask = nil
        resultTask = nil
        transcriptionSegments = []

        let inputNode = audioEngine.inputNode
        let naturalFormat = inputNode.outputFormat(forBus: 0)
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: naturalFormat
        ) ?? naturalFormat

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceInputError.invalidInputFormat
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        self.analyzer = analyzer
        self.transcriber = transcriber

        let (inputStream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputContinuation = continuation

        resultTask = Task { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    await MainActor.run {
                        self?.applyTranscriptionResult(result)
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.statusMessage = Self.friendlyMessage(for: error)
                    AppLog.voice.error("Speech transcription results failed error=\(error.localizedDescription, privacy: .public)")
                    self.stopRecording()
                }
            }
        }

        analysisTask = Task { [weak self, analyzer] in
            do {
                _ = try await analyzer.analyzeSequence(inputStream)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch is CancellationError {
                AppLog.voice.debug("Speech analysis task cancelled")
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.statusMessage = Self.friendlyMessage(for: error)
                    AppLog.voice.error("Speech analysis failed error=\(error.localizedDescription, privacy: .public)")
                    self.stopRecording()
                }
            }
        }

        if hasInstalledTap {
            inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        // The tap block runs on the realtime audio thread; copy the buffer before
        // handing it to the async analysis stream so later engine reuse cannot
        // mutate memory still being analyzed.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            let analysisBuffer = Self.copyBuffer(buffer) ?? buffer
            continuation.yield(AnalyzerInput(buffer: analysisBuffer))
        }
        hasInstalledTap = true

        audioEngine.prepare()
        try audioEngine.start()
        AppLog.voice.debug("Audio engine started sampleRate=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public)")
    }

    private func applyTranscriptionResult(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let index = transcriptionSegments.firstIndex(where: { $0.range == result.range }) {
            transcriptionSegments[index].text = text
        } else {
            transcriptionSegments.append(TranscriptionSegment(range: result.range, text: text))
        }

        transcriptionSegments.sort {
            CMTimeCompare($0.range.start, $1.range.start) < 0
        }
        transcript = transcriptionSegments.map(\.text).joined(separator: " ")
        AppLog.voice.debug("Speech transcription updated segments=\(self.transcriptionSegments.count, privacy: .public) characters=\(self.transcript.count, privacy: .public)")
    }

    private nonisolated static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }

        copy.frameLength = buffer.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<sourceBuffers.count {
            guard let source = sourceBuffers[index].mData,
                  let destination = destinationBuffers[index].mData
            else {
                continue
            }
            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            memcpy(destination, source, byteCount)
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }

        return copy
    }
}

private struct TranscriptionSegment {
    var range: CMTimeRange
    var text: String
}

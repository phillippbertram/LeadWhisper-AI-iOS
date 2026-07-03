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
    nonisolated static let isTemporarilyDisabled = false
    nonisolated static let temporarilyDisabledMessage = "Voice input is temporarily disabled. Type the transcript instead."
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

    @ObservationIgnored
    private var recordingSession: SpeechRecordingSession?
    @ObservationIgnored
    private var eventTask: Task<Void, Never>?

    /// True while any audio or recognition resources are live.
    private var hasActiveAudioWork: Bool {
        state != .idle || recordingSession != nil || eventTask != nil
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
            let session = SpeechRecordingSession(transcriber: transcriber)
            let events = try await session.start()
            recordingSession = session
            eventTask = Task { [weak self] in
                await self?.consumeRecordingEvents(events)
            }
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
            stopRecording(finalStatus: statusMessage)
        }
    }

    func stopRecording() {
        stopRecording(finalStatus: nil)
    }

    private func stopRecording(finalStatus: String?, cancelEventTask: Bool = true) {
        guard hasActiveAudioWork else {
            if let finalStatus {
                statusMessage = finalStatus
            }
            state = .idle
            return
        }

        let sessionToStop = recordingSession
        recordingSession = nil
        if cancelEventTask {
            eventTask?.cancel()
        }
        eventTask = nil
        state = .idle
        statusMessage = finalStatus ?? (transcript.isEmpty ? recordingCapability.message : "Transcript captured")
        Task {
            await sessionToStop?.stop()
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

    private func consumeRecordingEvents(_ events: AsyncThrowingStream<VoiceRecordingEvent, any Error>) async {
        do {
            for try await event in events {
                handle(event)
            }
            if state == .recording {
                stopRecording(finalStatus: transcript.isEmpty ? recordingCapability.message : "Transcript captured", cancelEventTask: false)
            }
        } catch is CancellationError {
            AppLog.voice.debug("Voice recording event task cancelled")
        } catch {
            handleRecordingError(error)
        }
    }

    private func handle(_ event: VoiceRecordingEvent) {
        switch event {
        case .status(let message):
            statusMessage = message
        case .transcript(let transcript):
            self.transcript = transcript
        case .finished:
            if state == .recording {
                stopRecording(finalStatus: transcript.isEmpty ? recordingCapability.message : "Transcript captured", cancelEventTask: false)
            }
        }
    }

    private func handleRecordingError(_ error: Error) {
        let message = Self.friendlyMessage(for: error)
        statusMessage = message
        AppLog.voice.error("Voice recording stream failed error=\(error.localizedDescription, privacy: .public)")
        if Self.isUnavailableAudioError(error) {
            recordingCapability = .unavailable(message)
        }
        stopRecording(finalStatus: message, cancelEventTask: false)
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
        guard !Self.isTemporarilyDisabled else {
            return .unavailable(Self.temporarilyDisabledMessage)
        }

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

        try await Self.reserveTranscriptionLocaleIfNeeded(locale)

        AppLog.voice.debug("SpeechTranscriber selected locale=\(locale.identifier, privacy: .public)")
        return SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }

    /// SpeechAnalyzer modules fail at analysis time ("unallocated locales")
    /// unless their locale is reserved with the system asset inventory first.
    private static func reserveTranscriptionLocaleIfNeeded(_ locale: Locale) async throws {
        let reservedLocales = await AssetInventory.reservedLocales
        guard !reservedLocales.contains(locale) else { return }
        try await AssetInventory.reserve(locale: locale)
        AppLog.voice.info("Speech transcription locale reserved locale=\(locale.identifier, privacy: .public)")
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

}

private enum VoiceRecordingEvent: Sendable {
    case status(String)
    case transcript(String)
    case finished
}

@MainActor
private final class SpeechRecordingSession {
    private let audioEngine = AVAudioEngine()
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber

    /// Raw mic-format buffers wrapped in `AnalyzerInput` purely because it is
    /// the framework's Sendable box for crossing off the audio tap thread.
    private var rawBufferContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var eventContinuation: AsyncThrowingStream<VoiceRecordingEvent, any Error>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var conversionTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var finalizedSegments: [TranscriptionSegment] = []
    private var volatileText = ""
    private var hasInstalledTap = false
    private var hasFinished = false

    init(transcriber: SpeechTranscriber) {
        self.transcriber = transcriber
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
    }

    func start() async throws -> AsyncThrowingStream<VoiceRecordingEvent, any Error> {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw VoiceInputError.invalidInputFormat
        }

        // The analyzer traps (EXC_BREAKPOINT) when fed buffers in a format the
        // transcriber model does not support, so analysis runs in the model's
        // preferred format and every tap buffer is converted into it first.
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: inputFormat
        ) else {
            AppLog.voice.warning("No compatible analyzer audio format for inputSampleRate=\(inputFormat.sampleRate, privacy: .public)")
            throw VoiceInputError.invalidInputFormat
        }

        let eventPipe = AsyncThrowingStream<VoiceRecordingEvent, any Error>.makeStream(
            of: VoiceRecordingEvent.self,
            throwing: (any Error).self
        )
        eventContinuation = eventPipe.continuation

        do {
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
            let bufferPipe = AsyncStream.makeStream(of: AnalyzerInput.self)
            rawBufferContinuation = bufferPipe.continuation
            let inputPipe = AsyncStream.makeStream(of: AnalyzerInput.self)
            inputContinuation = inputPipe.continuation
            startResultTask()
            startAnalysisTask(inputStream: inputPipe.stream)
            startConversionTask(
                buffers: bufferPipe.stream,
                analyzerFormat: analyzerFormat,
                continuation: inputPipe.continuation
            )
            installTap(on: inputNode, format: inputFormat, continuation: bufferPipe.continuation)
            audioEngine.prepare()
            try audioEngine.start()
            eventContinuation?.yield(.status("Listening..."))
            AppLog.voice.debug("Audio engine started inputSampleRate=\(inputFormat.sampleRate, privacy: .public) inputChannels=\(inputFormat.channelCount, privacy: .public) analyzerSampleRate=\(analyzerFormat.sampleRate, privacy: .public)")
            return eventPipe.stream
        } catch {
            finish(throwing: error)
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    func stop() async {
        finish(throwing: nil)
        await analyzer.cancelAndFinishNow()
    }

    private func startResultTask() {
        resultTask = Task { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    await MainActor.run {
                        self?.applyTranscriptionResult(result)
                    }
                }
            } catch is CancellationError {
                AppLog.voice.debug("Speech transcription results task cancelled")
            } catch {
                await MainActor.run {
                    self?.finish(throwing: error)
                    AppLog.voice.error("Speech transcription results failed error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func startAnalysisTask(inputStream: AsyncStream<AnalyzerInput>) {
        analysisTask = Task { [weak self, analyzer] in
            do {
                _ = try await analyzer.analyzeSequence(inputStream)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                await MainActor.run {
                    self?.finish(throwing: nil)
                }
            } catch is CancellationError {
                AppLog.voice.debug("Speech analysis task cancelled")
            } catch {
                await MainActor.run {
                    self?.finish(throwing: error)
                    AppLog.voice.error("Speech analysis failed error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func startConversionTask(
        buffers: AsyncStream<AnalyzerInput>,
        analyzerFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        conversionTask = Task {
            let converter = PCMBufferConverter(outputFormat: analyzerFormat)
            for await rawInput in buffers {
                guard let converted = converter.convert(rawInput.buffer) else { continue }
                continuation.yield(AnalyzerInput(buffer: converted))
            }
            continuation.finish()
        }
    }

    private func installTap(
        on inputNode: AVAudioInputNode,
        format inputFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        if hasInstalledTap {
            inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable buffer, _ in
            guard let copiedBuffer = Self.copyBuffer(buffer) else { return }
            continuation.yield(AnalyzerInput(buffer: copiedBuffer))
        }
        hasInstalledTap = true
    }

    private func applyTranscriptionResult(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)

        if result.isFinal {
            // Final results are committed, non-overlapping chunks. The volatile
            // hypotheses covered the same audio, so drop the transient tail.
            volatileText = ""
            if !text.isEmpty {
                if let index = finalizedSegments.firstIndex(where: { $0.range == result.range }) {
                    finalizedSegments[index].text = text
                } else {
                    finalizedSegments.append(TranscriptionSegment(range: result.range, text: text))
                }
                finalizedSegments.sort {
                    CMTimeCompare($0.range.start, $1.range.start) < 0
                }
            }
        } else {
            // Volatile results are progressive hypotheses over the tail of the
            // audio; their range grows each update, so accumulating them by range
            // duplicated the transcript. Keep only the latest as a transient tail.
            volatileText = text
        }

        var parts = finalizedSegments.map(\.text)
        if !volatileText.isEmpty {
            parts.append(volatileText)
        }
        let transcript = parts.joined(separator: " ")
        eventContinuation?.yield(.transcript(transcript))
        AppLog.voice.debug("Speech transcription updated finalized=\(self.finalizedSegments.count, privacy: .public) volatile=\(self.volatileText.isEmpty ? 0 : 1, privacy: .public) characters=\(transcript.count, privacy: .public)")
    }

    private func finish(throwing error: Error?) {
        guard !hasFinished else { return }
        hasFinished = true

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }

        rawBufferContinuation?.finish()
        rawBufferContinuation = nil
        inputContinuation?.finish()
        inputContinuation = nil
        analysisTask?.cancel()
        conversionTask?.cancel()
        resultTask?.cancel()
        analysisTask = nil
        conversionTask = nil
        resultTask = nil

        if let error {
            eventContinuation?.finish(throwing: error)
        } else {
            eventContinuation?.yield(.finished)
            eventContinuation?.finish()
        }
        eventContinuation = nil
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

/// Converts microphone-format PCM buffers into the analyzer's required format
/// (typically 16 kHz mono) before they are handed to `SpeechAnalyzer`.
private final class PCMBufferConverter {
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inputFormat = buffer.format
        guard inputFormat != outputFormat else { return buffer }

        if converter == nil || converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            // Sacrifices the first samples to keep buffer timestamps free of
            // resampler priming drift, matching Apple's transcription sample.
            converter?.primeMethod = .none
        }
        guard let converter else {
            AppLog.voice.error("Audio converter unavailable inputSampleRate=\(inputFormat.sampleRate, privacy: .public) outputSampleRate=\(self.outputFormat.sampleRate, privacy: .public)")
            return nil
        }

        let sampleRateRatio = outputFormat.sampleRate / inputFormat.sampleRate
        let frameCapacity = AVAudioFrameCount((Double(buffer.frameLength) * sampleRateRatio).rounded(.up))
        guard frameCapacity > 0,
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity)
        else {
            return nil
        }

        var conversionError: NSError?
        var consumedInput = false
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if consumedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error else {
            AppLog.voice.error("Audio buffer conversion failed error=\(conversionError?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }
        return outputBuffer
    }
}

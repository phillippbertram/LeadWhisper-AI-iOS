import Foundation
import OSLog
import Speech

extension VoiceInputService {
    /// Cheap baseline check safe to run during view construction: it reads the
    /// Info.plist configuration but does not allocate speech-service connections.
    /// Recognizer availability is verified in `refreshRecordingCapability()`
    /// when recording actually starts.
    static func defaultRecordingCapability() -> VoiceRecordingCapability {
        #if targetEnvironment(simulator)
        .unavailable(unavailableMessage)
        #else
        if let configurationError = speechRecognitionConfigurationError() {
            return .unavailable(configurationError.errorDescription ?? unavailableMessage)
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

    static func speechRecognitionConfigurationError() -> VoiceInputError? {
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

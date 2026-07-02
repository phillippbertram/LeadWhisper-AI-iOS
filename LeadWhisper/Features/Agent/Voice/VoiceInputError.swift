import Foundation

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

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

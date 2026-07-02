import Foundation

enum ActivityEntityKind: String, CaseIterable, Codable, Sendable {
    case contact
    case opportunity
    case followUp
    case interaction
    case system

    nonisolated var systemImage: String {
        switch self {
        case .contact:
            "person.crop.circle"
        case .opportunity:
            "chart.line.uptrend.xyaxis"
        case .followUp:
            "bell"
        case .interaction:
            "text.bubble"
        case .system:
            "sparkles"
        }
    }
}

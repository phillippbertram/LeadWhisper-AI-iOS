import Foundation

enum AgentProviderKind: String, CaseIterable, Identifiable, Sendable {
    case appleFoundationModels
    case openAI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleFoundationModels:
            "Apple On-device"
        case .openAI:
            "OpenAI"
        }
    }

    var statusLabel: String {
        switch self {
        case .appleFoundationModels:
            "Apple on-device"
        case .openAI:
            "OpenAI cloud"
        }
    }

    var modelDisplayName: String {
        switch self {
        case .appleFoundationModels:
            "Apple Foundation Models"
        case .openAI:
            "GPT 5.5"
        }
    }

    var modelStatusLabel: String {
        modelDisplayName
    }

    var privacySystemImage: String {
        switch self {
        case .appleFoundationModels:
            "lock.shield"
        case .openAI:
            "network"
        }
    }

    static func selected(from defaults: UserDefaults = .standard) -> AgentProviderKind {
        let value = defaults.string(forKey: AgentSettings.providerKindKey)
        return value.flatMap(AgentProviderKind.init(rawValue:)) ?? .appleFoundationModels
    }
}

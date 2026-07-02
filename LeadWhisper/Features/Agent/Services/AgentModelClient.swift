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

struct AgentModelTurnRequest {
    var prompt: String
    var condensed: Bool
    var toolScope: AgentToolScope
    var instructions: String
    var responseTokenLimit: Int
    var maxToolCalls: Int
    var dataSource: AgentToolDataSource
}

struct AgentModelPlanRequest {
    var prompt: String
    var instructions: String
    var responseTokenLimit: Int
}

struct AgentModelTurnResponse {
    var turn: AgentTurn
    var timeline: [AgentTimelineItem]
}

struct AgentModelContextRequest {
    var promptText: String
    var instructions: String
    var toolScope: AgentToolScope
    var dataSource: AgentToolDataSource
    var memoryPrompt: String?
    var responseReserveTokens: Int
}

@MainActor
protocol AgentModelClient: AnyObject {
    var providerKind: AgentProviderKind { get }
    var isAvailable: Bool { get }
    var availabilityMessage: String { get }
    var unavailableErrorMessage: String { get }
    var contextSize: Int { get }

    func prewarm(dataSource: AgentToolDataSource)
    func resetSession()
    func planTools(for request: AgentModelPlanRequest) async throws -> AgentToolPlan
    func respond(to request: AgentModelTurnRequest) async throws -> AgentModelTurnResponse
    func measuredContextWindowUsage(for request: AgentModelContextRequest) async throws -> AgentContextWindowUsage
    func estimatedContextWindowUsage(for request: AgentModelContextRequest) -> AgentContextWindowUsage
    func isContextWindowError(_ error: Error) -> Bool
}

@MainActor
final class AgentModelClientRegistry {
    private let credentialStore: AgentCredentialStore
    private lazy var appleClient = FoundationModelsAgentClient()
    private lazy var openAIClient = OpenAIResponsesAgentClient(credentialStore: credentialStore)

    init(credentialStore: AgentCredentialStore) {
        self.credentialStore = credentialStore
    }

    func selectedClient() -> any AgentModelClient {
        client(for: AgentProviderKind.selected())
    }

    func client(for providerKind: AgentProviderKind) -> any AgentModelClient {
        switch providerKind {
        case .appleFoundationModels:
            appleClient
        case .openAI:
            openAIClient
        }
    }
}

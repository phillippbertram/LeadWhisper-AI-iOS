import Foundation

public struct AgentModelCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let structuredOutput = AgentModelCapabilities(rawValue: 1 << 0)
    public static let toolCalling = AgentModelCapabilities(rawValue: 1 << 1)
    public static let tokenCounting = AgentModelCapabilities(rawValue: 1 << 2)
    public static let statefulSession = AgentModelCapabilities(rawValue: 1 << 3)
}

public struct AgentModelDescriptor: Sendable, Hashable {
    public var id: String
    public var displayName: String
    public var contextWindow: Int
    public var capabilities: AgentModelCapabilities

    public init(
        id: String,
        displayName: String,
        contextWindow: Int,
        capabilities: AgentModelCapabilities
    ) {
        self.id = id
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.capabilities = capabilities
    }
}

public struct AgentModelAvailability: Sendable, Hashable {
    public var isAvailable: Bool
    public var message: String
    public var unavailableMessage: String

    public init(isAvailable: Bool, message: String, unavailableMessage: String) {
        self.isAvailable = isAvailable
        self.message = message
        self.unavailableMessage = unavailableMessage
    }
}

public struct AgentContextUsage: Sendable, Hashable {
    public var usedTokens: Int
    public var maximumTokens: Int
    public var inputTokens: Int
    public var memoryTokens: Int
    public var responseReserveTokens: Int
    public var toolNames: [String]
    public var isEstimated: Bool

    public init(
        usedTokens: Int,
        maximumTokens: Int,
        inputTokens: Int,
        memoryTokens: Int,
        responseReserveTokens: Int,
        toolNames: [String],
        isEstimated: Bool
    ) {
        self.usedTokens = usedTokens
        self.maximumTokens = maximumTokens
        self.inputTokens = inputTokens
        self.memoryTokens = memoryTokens
        self.responseReserveTokens = responseReserveTokens
        self.toolNames = toolNames
        self.isEstimated = isEstimated
    }

    public var availableTokens: Int {
        max(0, maximumTokens - usedTokens - responseReserveTokens)
    }
}

public enum AgentSessionMode: Sendable, Hashable {
    case conversation
    case ephemeral
}

public struct AgentModelRequest: Sendable {
    public var prompt: String
    public var memoryPrompt: String?
    public var instructions: String
    public var outputName: String
    public var outputSchema: AgentSchema
    public var tools: [AnyAgentTool]
    public var responseTokenLimit: Int
    public var sessionMode: AgentSessionMode
    public var condensed: Bool

    public init(
        prompt: String,
        memoryPrompt: String? = nil,
        instructions: String,
        outputName: String,
        outputSchema: AgentSchema,
        tools: [AnyAgentTool],
        responseTokenLimit: Int,
        sessionMode: AgentSessionMode = .conversation,
        condensed: Bool = false
    ) {
        self.prompt = prompt
        self.memoryPrompt = memoryPrompt
        self.instructions = instructions
        self.outputName = outputName
        self.outputSchema = outputSchema
        self.tools = tools
        self.responseTokenLimit = responseTokenLimit
        self.sessionMode = sessionMode
        self.condensed = condensed
    }
}

public struct AgentModelResponse: Sendable {
    public var output: JSONValue

    public init(output: JSONValue) {
        self.output = output
    }
}

public enum AgentModelErrorClassification: String, Sendable, Hashable {
    case contextWindow
    case authentication
    case rateLimited
    case transient
    case invalidRequest
    case cancelled
    case unknown
}

public protocol AgentModel: Sendable {
    var descriptor: AgentModelDescriptor { get }

    func availability() async -> AgentModelAvailability
    func prewarm(tools: [AnyAgentTool]) async
    func reset() async
    func invoke(_ request: AgentModelRequest, executor: AgentToolExecutor) async throws -> AgentModelResponse
    func contextUsage(for request: AgentModelRequest) async throws -> AgentContextUsage
    func estimatedContextUsage(for request: AgentModelRequest) async -> AgentContextUsage
    func classify(_ error: any Error) async -> AgentModelErrorClassification
}

public extension AgentModel {
    func isContextWindowError(_ error: any Error) async -> Bool {
        await classify(error) == .contextWindow
    }
}

public enum AgentEvent: Sendable, Hashable {
    case invocationStarted
    case toolSelection(names: [String], reason: String)
    case modelStarted(modelID: String)
    case toolStarted(name: String, arguments: String)
    case toolFinished(name: String, observation: String)
    case modelCompleted(modelID: String)
    case contextCondensed
    case invocationCompleted
    case invocationFailed(message: String)
}

public struct AnyAgentHook: Sendable {
    private let receiveEvent: @Sendable (AgentEvent) async -> Void

    public init(_ receive: @escaping @Sendable (AgentEvent) async -> Void) {
        receiveEvent = receive
    }

    public func receive(_ event: AgentEvent) async {
        await receiveEvent(event)
    }
}

public struct AgentPolicy: Sendable, Hashable {
    public var maximumToolCalls: Int
    public var blocksRepeatedToolCalls: Bool
    public var responseTokenLimit: Int
    public var timeout: Duration
    public var retriesContextOverflowOnce: Bool

    public init(
        maximumToolCalls: Int,
        blocksRepeatedToolCalls: Bool = true,
        responseTokenLimit: Int,
        timeout: Duration = .seconds(20),
        retriesContextOverflowOnce: Bool = true
    ) {
        self.maximumToolCalls = maximumToolCalls
        self.blocksRepeatedToolCalls = blocksRepeatedToolCalls
        self.responseTokenLimit = responseTokenLimit
        self.timeout = timeout
        self.retriesContextOverflowOnce = retriesContextOverflowOnce
    }
}

public struct AgentRun<Output: Sendable>: Sendable {
    public var output: Output
    public var events: [AgentEvent]
    public var selectedToolNames: [String]
    public var contextUsage: AgentContextUsage
    public var condensed: Bool

    public init(
        output: Output,
        events: [AgentEvent],
        selectedToolNames: [String],
        contextUsage: AgentContextUsage,
        condensed: Bool
    ) {
        self.output = output
        self.events = events
        self.selectedToolNames = selectedToolNames
        self.contextUsage = contextUsage
        self.condensed = condensed
    }
}

public enum AgentRuntimeError: LocalizedError, Sendable {
    case modelUnavailable(String)
    case timeout
    case toolBudgetExceeded(String)
    case unknownTool(String)
    case invalidToolArguments(String)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let message):
            message
        case .timeout:
            "The agent invocation timed out."
        case .toolBudgetExceeded(let reason):
            "Agent tool budget exceeded. \(reason)"
        case .unknownTool(let name):
            "The model requested an unavailable tool: \(name)."
        case .invalidToolArguments(let reason):
            "The model returned invalid tool arguments. \(reason)"
        }
    }
}

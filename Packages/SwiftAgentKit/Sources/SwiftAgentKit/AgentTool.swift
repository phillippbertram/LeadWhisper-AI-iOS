import Foundation

public struct AgentToolContext: Sendable, Hashable {
    public var invocationID: UUID
    public var callID: String?

    public init(invocationID: UUID, callID: String? = nil) {
        self.invocationID = invocationID
        self.callID = callID
    }
}

public struct AgentToolResult: Sendable, Hashable {
    public var modelContent: String
    public var traceSummary: String

    public init(modelContent: String, traceSummary: String? = nil) {
        self.modelContent = modelContent
        self.traceSummary = traceSummary ?? modelContent
    }
}

public protocol AgentTool<Arguments>: Sendable where Arguments: Decodable & Sendable {
    associatedtype Arguments

    var name: String { get }
    var description: String { get }
    var argumentsSchema: AgentSchema { get }
    func call(arguments: Arguments, context: AgentToolContext) async throws -> AgentToolResult
}

public struct AnyAgentTool: Sendable {
    public var name: String
    public var description: String
    public var argumentsSchema: AgentSchema
    private let invoke: @Sendable (JSONValue, AgentToolContext) async throws -> AgentToolResult

    public init<T: AgentTool>(_ tool: T) {
        name = tool.name
        description = tool.description
        argumentsSchema = tool.argumentsSchema
        invoke = { value, context in
            let arguments: T.Arguments
            do {
                arguments = try JSONValue.decode(T.Arguments.self, from: value)
            } catch {
                throw AgentRuntimeError.invalidToolArguments(error.localizedDescription)
            }
            return try await tool.call(arguments: arguments, context: context)
        }
    }

    public func call(arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolResult {
        try await invoke(arguments, context)
    }
}

public actor AgentToolExecutor {
    private let toolsByName: [String: AnyAgentTool]
    private let policy: AgentPolicy
    private let hooks: [AnyAgentHook]
    private let invocationID: UUID
    private var callCount = 0
    private var callKeys: Set<String> = []
    private var events: [AgentEvent] = []

    public init(
        tools: [AnyAgentTool],
        policy: AgentPolicy,
        hooks: [AnyAgentHook],
        invocationID: UUID = UUID()
    ) {
        toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        self.policy = policy
        self.hooks = hooks
        self.invocationID = invocationID
    }

    public func execute(name: String, arguments: JSONValue, callID: String? = nil) async throws -> AgentToolResult {
        callCount += 1
        guard callCount <= policy.maximumToolCalls else {
            throw AgentRuntimeError.toolBudgetExceeded("Local lookup budget exhausted.")
        }

        let argumentDescription = Self.compactJSON(arguments)
        let callKey = "\(name):\(argumentDescription)"
        if policy.blocksRepeatedToolCalls, !callKeys.insert(callKey).inserted {
            throw AgentRuntimeError.toolBudgetExceeded("Repeated local lookup blocked.")
        }

        guard let tool = toolsByName[name] else {
            throw AgentRuntimeError.unknownTool(name)
        }

        await emit(.toolStarted(name: name, arguments: argumentDescription))
        let result = try await tool.call(
            arguments: arguments,
            context: AgentToolContext(invocationID: invocationID, callID: callID)
        )
        await emit(.toolFinished(name: name, observation: Self.snippet(result.traceSummary)))
        return result
    }

    public func recordedEvents() -> [AgentEvent] {
        events
    }

    private func emit(_ event: AgentEvent) async {
        events.append(event)
        for hook in hooks {
            await hook.receive(event)
        }
    }

    private static func compactJSON(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return String(text.prefix(160))
    }

    private static func snippet(_ text: String) -> String {
        guard text.count > 160 else { return text }
        return "\(text.prefix(157))..."
    }
}

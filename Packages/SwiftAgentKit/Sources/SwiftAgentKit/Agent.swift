import Foundation

public actor Agent<Output: Decodable & Sendable> {
    public nonisolated let model: any AgentModel
    public nonisolated let outputSchema: AgentOutputSchema<Output>

    private let instructions: @Sendable ([String]) -> String
    private let tools: [AnyAgentTool]
    private let memory: any AgentMemory
    private let toolSelector: AnyAgentToolSelector
    private let hooks: [AnyAgentHook]
    private let policy: AgentPolicy

    public init(
        model: any AgentModel,
        instructions: @escaping @Sendable ([String]) -> String,
        outputSchema: AgentOutputSchema<Output>,
        tools: [AnyAgentTool],
        memory: any AgentMemory,
        toolSelector: AnyAgentToolSelector = .all,
        hooks: [AnyAgentHook] = [],
        policy: AgentPolicy
    ) {
        self.model = model
        self.instructions = instructions
        self.outputSchema = outputSchema
        self.tools = tools
        self.memory = memory
        self.toolSelector = toolSelector
        self.hooks = hooks
        self.policy = policy
    }

    public init(
        model: any AgentModel,
        instructions: String,
        outputSchema: AgentOutputSchema<Output>,
        tools: [AnyAgentTool],
        memory: any AgentMemory,
        toolSelector: AnyAgentToolSelector = .all,
        hooks: [AnyAgentHook] = [],
        policy: AgentPolicy
    ) {
        self.init(
            model: model,
            instructions: { _ in instructions },
            outputSchema: outputSchema,
            tools: tools,
            memory: memory,
            toolSelector: toolSelector,
            hooks: hooks,
            policy: policy
        )
    }

    public func availability() async -> AgentModelAvailability {
        await model.availability()
    }

    public func prewarm() async {
        await model.prewarm(tools: tools)
    }

    public func reset() async {
        await model.reset()
        await memory.reset()
    }

    public func resetModelSession() async {
        await model.reset()
    }

    public func record(_ entry: AgentMemoryEntry) async {
        await memory.record(entry)
    }

    public func contextUsage(for input: String, toolNames: [String]? = nil) async -> AgentContextUsage {
        let selectedNames = toolNames ?? tools.map(\.name)
        let selectedTools = tools.filter { selectedNames.contains($0.name) }
        let memoryPrompt = await memory.context()
        let request = makeRequest(
            input: input,
            memoryPrompt: memoryPrompt,
            tools: selectedTools,
            condensed: false
        )
        do {
            return try await model.contextUsage(for: request)
        } catch {
            return await model.estimatedContextUsage(for: request)
        }
    }

    public func run(_ input: String) async throws -> AgentRun<Output> {
        var events: [AgentEvent] = []
        await emit(.invocationStarted, into: &events)

        let availability = await model.availability()
        guard availability.isAvailable else {
            throw AgentRuntimeError.modelUnavailable(availability.unavailableMessage)
        }

        let selection = await toolSelector.select(for: input, from: tools)
        let selectedTools = tools.filter { selection.toolNames.contains($0.name) }
        await emit(
            .toolSelection(names: selectedTools.map(\.name), reason: selection.reason),
            into: &events
        )

        let memoryPrompt = await memory.context()
        let executor = AgentToolExecutor(tools: selectedTools, policy: policy, hooks: hooks)
        do {
            let initial = makeRequest(
                input: input,
                memoryPrompt: memoryPrompt,
                tools: selectedTools,
                condensed: false
            )
            let response = try await invokeWithTimeout(initial, executor: executor, events: &events)
            return try await finish(
                response,
                input: input,
                request: initial,
                executor: executor,
                baseEvents: events,
                condensed: false
            )
        } catch {
            guard policy.retriesContextOverflowOnce,
                  await model.classify(error) == .contextWindow else {
                await emit(.invocationFailed(message: error.localizedDescription), into: &events)
                throw error
            }

            await model.reset()
            await emit(.contextCondensed, into: &events)
            let condensedPrompt = "Note: the earlier provider context window was exceeded. Continue from compact memory and ask for exact details if anything is missing."
            let retry = makeRequest(
                input: "\(condensedPrompt)\n\(input)",
                memoryPrompt: memoryPrompt,
                tools: selectedTools,
                condensed: true
            )
            do {
                let response = try await invokeWithTimeout(retry, executor: executor, events: &events)
                return try await finish(
                    response,
                    input: input,
                    request: retry,
                    executor: executor,
                    baseEvents: events,
                    condensed: true
                )
            } catch {
                await emit(.invocationFailed(message: error.localizedDescription), into: &events)
                throw error
            }
        }
    }

    private func makeRequest(
        input: String,
        memoryPrompt: String?,
        tools: [AnyAgentTool],
        condensed: Bool
    ) -> AgentModelRequest {
        AgentModelRequest(
            prompt: input,
            memoryPrompt: memoryPrompt,
            instructions: instructions(tools.map(\.name)),
            outputName: outputSchema.name,
            outputSchema: outputSchema.schema,
            tools: tools,
            responseTokenLimit: policy.responseTokenLimit,
            sessionMode: .conversation,
            condensed: condensed
        )
    }

    private func invokeWithTimeout(
        _ request: AgentModelRequest,
        executor: AgentToolExecutor,
        events: inout [AgentEvent]
    ) async throws -> AgentModelResponse {
        await emit(.modelStarted(modelID: model.descriptor.id), into: &events)
        let clock = ContinuousClock()
        return try await withThrowingTaskGroup(of: AgentModelResponse.self) { group in
            group.addTask {
                try await self.model.invoke(request, executor: executor)
            }
            group.addTask {
                try await clock.sleep(for: self.policy.timeout)
                throw AgentRuntimeError.timeout
            }
            guard let first = try await group.next() else {
                throw AgentRuntimeError.timeout
            }
            group.cancelAll()
            return first
        }
    }

    private func finish(
        _ response: AgentModelResponse,
        input: String,
        request: AgentModelRequest,
        executor: AgentToolExecutor,
        baseEvents: [AgentEvent],
        condensed: Bool
    ) async throws -> AgentRun<Output> {
        var events = baseEvents
        events.append(contentsOf: await executor.recordedEvents())
        await emit(.modelCompleted(modelID: model.descriptor.id), into: &events)
        let output = try outputSchema.decode(response.output)
        await memory.record(.user(input))
        if let text = Self.memoryText(from: response.output) {
            await memory.record(.assistant(text))
        }
        await emit(.invocationCompleted, into: &events)
        let contextUsage: AgentContextUsage
        do {
            contextUsage = try await model.contextUsage(for: request)
        } catch {
            contextUsage = await model.estimatedContextUsage(for: request)
        }
        return AgentRun(
            output: output,
            events: events,
            selectedToolNames: request.tools.map(\.name),
            contextUsage: contextUsage,
            condensed: condensed
        )
    }

    private func emit(_ event: AgentEvent, into events: inout [AgentEvent]) async {
        events.append(event)
        for hook in hooks {
            await hook.receive(event)
        }
    }

    private static func memoryText(from output: JSONValue) -> String? {
        if let message = output["message"]?.stringValue {
            return message
        }
        guard let data = try? JSONEncoder().encode(output) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

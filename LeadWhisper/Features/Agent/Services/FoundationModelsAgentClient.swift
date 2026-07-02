import Foundation
import FoundationModels
import OSLog

@MainActor
final class FoundationModelsAgentClient: AgentModelClient {
    let providerKind: AgentProviderKind = .appleFoundationModels

    private let model = SystemLanguageModel.default
    private var session: LanguageModelSession?
    private var activeToolScope: AgentToolScope?
    private var fallbackSessionTokens = 0

    var isAvailable: Bool {
        model.isAvailable
    }

    var availabilityMessage: String {
        Self.availabilityMessage(for: model.availability)
    }

    var unavailableErrorMessage: String {
        "LeadWhisper needs Apple Foundation Models to draft CRM changes. \(availabilityMessage) No local data was changed."
    }

    var contextSize: Int {
        model.contextSize
    }

    func prewarm(dataSource: AgentToolDataSource) {
        guard model.isAvailable else { return }
        ensureSession(toolScope: .full, dataSource: dataSource).prewarm()
        AppLog.agent.debug("SystemLanguageModel prewarm requested at UI appear")
    }

    func resetSession() {
        session = nil
        activeToolScope = nil
        fallbackSessionTokens = 0
    }

    func planTools(for request: AgentModelPlanRequest) async throws -> AgentToolPlan {
        let planningSession = LanguageModelSession(model: model, instructions: request.instructions)
        let response = try await planningSession.respond(
            to: request.prompt,
            generating: AgentToolPlan.self,
            includeSchemaInPrompt: false,
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: request.responseTokenLimit)
        )
        return response.content
    }

    func respond(to request: AgentModelTurnRequest) async throws -> AgentModelTurnResponse {
        let session = ensureSession(toolScope: request.toolScope, dataSource: request.dataSource)

        // Greedy sampling makes extraction deterministic; temperature has no
        // effect under greedy, so it is intentionally omitted.
        let response = try await session.respond(
            to: request.prompt,
            generating: AgentTurn.self,
            includeSchemaInPrompt: false,
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: request.responseTokenLimit)
        )

        let turn = response.content
        let timeline = timeline(from: response.transcriptEntries, thought: turn.thought, condensed: request.condensed)
        await refreshFallbackSessionTokens(session: session, prompt: request.prompt, turn: turn)
        return AgentModelTurnResponse(turn: turn, timeline: timeline)
    }

    func measuredContextWindowUsage(for request: AgentModelContextRequest) async throws -> AgentContextWindowUsage {
        let promptTokens = try await model.tokenCount(for: Prompt(request.promptText))
        let schemaTokens = try await model.tokenCount(for: AgentTurn.generationSchema)
        let memoryTokens = try await measuredMemoryTokens(request.memoryPrompt)
        let baseTokens: Int

        if let session, activeToolScope == request.toolScope {
            baseTokens = try await measuredTranscriptTokens(for: session.transcript)
        } else {
            let instructions = Instructions(request.instructions)
            let tools = request.toolScope.tools(dataSource: request.dataSource)
            async let instructionsTokens = model.tokenCount(for: instructions)
            async let toolsTokens = model.tokenCount(for: tools)
            let countedInstructions = try await instructionsTokens
            let countedTools = try await toolsTokens
            baseTokens = countedInstructions + countedTools
        }

        return AgentContextWindowUsage(
            usedTokens: min(contextSize, baseTokens + promptTokens + schemaTokens),
            maximumTokens: contextSize,
            inputTokens: promptTokens,
            memoryTokens: memoryTokens,
            responseReserveTokens: request.responseReserveTokens,
            toolScope: request.toolScope.rawValue,
            isEstimated: false
        )
    }

    func estimatedContextWindowUsage(for request: AgentModelContextRequest) -> AgentContextWindowUsage {
        let instructionsTokens = Self.roughTokenCount(request.instructions) + request.toolScope.toolCount * 90
        let sessionTokens = activeToolScope == request.toolScope && fallbackSessionTokens > 0 ? fallbackSessionTokens : instructionsTokens
        let inputTokens = Self.roughTokenCount(request.promptText)
        let schemaTokens = Self.roughTokenCount(AgentTurn.generationSchema.debugDescription)
        let usedTokens = min(contextSize, sessionTokens + inputTokens + schemaTokens)

        return AgentContextWindowUsage(
            usedTokens: usedTokens,
            maximumTokens: contextSize,
            inputTokens: inputTokens,
            memoryTokens: Self.roughTokenCount(request.memoryPrompt ?? ""),
            responseReserveTokens: request.responseReserveTokens,
            toolScope: request.toolScope.rawValue,
            isEstimated: true
        )
    }

    func isContextWindowError(_ error: Error) -> Bool {
        if let generationError = error as? LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = generationError {
                return true
            }
        }

        let message = error.localizedDescription.searchKey
        return message.contains("context window") || message.contains("model context")
    }

    private func ensureSession(toolScope: AgentToolScope, dataSource: AgentToolDataSource) -> LanguageModelSession {
        if let session, activeToolScope == toolScope {
            return session
        }

        let tools = toolScope.tools(dataSource: dataSource)
        let instructions = AgentConversationEngine.instructions(toolScope: toolScope)
        let session = LanguageModelSession(model: model, tools: tools, instructions: instructions)
        self.session = session
        activeToolScope = toolScope
        fallbackSessionTokens = Self.roughTokenCount(instructions) + tools.count * 90
        AppLog.agent.debug("Agent conversation session created provider=apple scope=\(toolScope.rawValue, privacy: .public) tools=\(tools.count, privacy: .public)")
        return session
    }

    private func refreshFallbackSessionTokens(session: LanguageModelSession, prompt: String, turn: AgentTurn) async {
        do {
            fallbackSessionTokens = try await measuredTranscriptTokens(for: session.transcript)
        } catch {
            fallbackSessionTokens += Self.roughTokenCount(prompt) +
                Self.roughTokenCount(turn.message) +
                Self.roughTokenCount(turn.thought)
        }
    }

    /// Counts transcript entries with Apple's dedicated transcript token API.
    /// `Transcript` itself is a collection, so the full session transcript can
    /// be passed here without manually rebuilding entries.
    private func measuredTranscriptTokens<Entries: Collection>(
        for transcriptEntries: Entries
    ) async throws -> Int where Entries.Element == Transcript.Entry {
        try await model.tokenCount(for: transcriptEntries)
    }

    private func measuredMemoryTokens(_ memory: String?) async throws -> Int {
        guard let memory else { return 0 }
        return try await model.tokenCount(for: Prompt(memory))
    }

    private func timeline(from entries: ArraySlice<Transcript.Entry>, thought: String, condensed: Bool) -> [AgentTimelineItem] {
        var items: [AgentTimelineItem] = []

        if condensed {
            items.append(AgentTimelineItem(title: "Context condensed", detail: "The conversation was restarted to fit the selected model.", systemImage: "arrow.triangle.2.circlepath"))
        }

        if let thought = thought.nilIfBlank {
            items.append(AgentTimelineItem(title: "Thought", detail: thought, systemImage: "brain"))
        }

        for entry in entries {
            switch entry {
            case .toolCalls(let calls):
                for call in calls {
                    items.append(AgentTimelineItem(title: "Action", detail: actionDetail(for: call), systemImage: "wrench.and.screwdriver"))
                }
            case .toolOutput(let output):
                let snippet = Self.textSnippet(from: output.segments)
                items.append(AgentTimelineItem(title: "Observation", detail: snippet.map { "\(output.toolName): \($0)" } ?? output.toolName, systemImage: "tray.full"))
            case .response:
                items.append(AgentTimelineItem(title: "Final answer", detail: "Structured AgentTurn received.", systemImage: "checkmark.seal"))
            case .prompt, .instructions:
                break
            @unknown default:
                items.append(AgentTimelineItem(title: "Transcript entry", detail: "Additional model event received.", systemImage: "ellipsis.message"))
            }
        }

        if !items.contains(where: { $0.title == "Final answer" }) {
            items.append(AgentTimelineItem(title: "Final answer", detail: "Structured AgentTurn received.", systemImage: "checkmark.seal"))
        }

        return items
    }

    private func actionDetail(for call: Transcript.ToolCall) -> String {
        let arguments = call.arguments.jsonString
        guard !arguments.isEmpty, arguments != "{}" else { return call.toolName }
        return "\(call.toolName) \(String(arguments.prefix(80)))"
    }

    /// Joins the plain-text parts of a tool output so the ReAct trace can show
    /// what the model actually observed, truncated to stay card-sized.
    private static func textSnippet(from segments: [Transcript.Segment]) -> String? {
        let text = segments
            .compactMap { segment -> String? in
                if case .text(let textSegment) = segment {
                    return textSegment.content
                }
                return nil
            }
            .joined(separator: " ")

        guard let compact = text.nilIfBlank else { return nil }
        guard compact.count > 160 else { return compact }
        return "\(compact.prefix(157))..."
    }

    private static func availabilityMessage(for availability: SystemLanguageModel.Availability) -> String {
        switch availability {
        case .available:
            "Apple Foundation Models available"
        case .unavailable(.appleIntelligenceNotEnabled):
            "Apple Intelligence is not enabled."
        case .unavailable(.deviceNotEligible):
            "This device is not eligible for Apple Intelligence."
        case .unavailable(.modelNotReady):
            "The on-device model is not ready yet."
        @unknown default:
            "Foundation Models availability is unknown."
        }
    }

    private static func roughTokenCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, Int((Double(text.count) / 4.0).rounded(.up)))
    }
}

extension AgentToolScope {
    func tools(dataSource: AgentToolDataSource) -> [any Tool] {
        switch self {
        case .none:
            []
        case .contacts:
            [
                FindContactsTool(dataSource: dataSource),
                GetContactDetailsTool(dataSource: dataSource)
            ]
        case .opportunities:
            [
                FindOpportunitiesTool(dataSource: dataSource)
            ]
        case .followUps:
            [
                FindFollowUpsTool(dataSource: dataSource)
            ]
        case .pipeline:
            [
                GetPipelineSummaryTool(dataSource: dataSource)
            ]
        case .full:
            [
                FindContactsTool(dataSource: dataSource),
                FindOpportunitiesTool(dataSource: dataSource),
                FindFollowUpsTool(dataSource: dataSource),
                GetContactDetailsTool(dataSource: dataSource),
                GetPipelineSummaryTool(dataSource: dataSource)
            ]
        }
    }
}

import Foundation
import FoundationModels
import Observation
import OSLog

/// Runs the agent chat loop on one persistent Foundation Models session so the
/// model keeps its own follow-up questions, answers, and tool results across
/// turns. Each turn follows the ReAct pattern: the model records a thought,
/// acts through read-only lookup tools, reads the observations, and finishes
/// with reply, clarify, or propose. The engine only works with real local CRM
/// data and never applies changes itself.
@MainActor
@Observable
final class AgentConversationEngine {
    /// Loop guards in the spirit of LangChain's AgentExecutor: bound the
    /// actions per turn and stop endless question rounds with a forced final
    /// answer. Context-window recovery is additionally bounded to one retry.
    private enum Limits {
        static let toolCallsPerTurn = 6
        static let consecutiveClarifications = 3
        static let repeatedClarificationRetries = 1
        static let turnTimeoutSeconds = 20
        static let userContextLines = 8
        static let responseTokens = 900
    }

    /// Label for the lookup the model is running right now, shown live in the
    /// processing bubble while a turn is in flight.
    private(set) var currentActivity: String?
    private(set) var contextWindowUsage: AgentContextWindowUsage
    private(set) var contextWindowEvent: AgentContextWindowEvent?

    private let model = SystemLanguageModel.default
    private let toolDataSource: AgentToolDataSource
    @ObservationIgnored private var session: LanguageModelSession?
    @ObservationIgnored private var activeToolScope: AgentToolScope?
    @ObservationIgnored private var fallbackSessionTokens = 0
    @ObservationIgnored private var contextMemory = AgentContextMemory()
    @ObservationIgnored private var pendingOutcomeNote: String?
    @ObservationIgnored private var guidedWorkflow: AgentGuidedWorkflow?
    @ObservationIgnored private var userContext = ""
    @ObservationIgnored private var toolCallsThisTurn = 0
    @ObservationIgnored private var toolCallCounts: [String: Int] = [:]
    @ObservationIgnored private var consecutiveClarifications = 0
    @ObservationIgnored private var lastClarificationKey: String?
    @ObservationIgnored private var repeatedClarificationCount = 0
    @ObservationIgnored private var contextUsageTask: Task<Void, Never>?

    init(toolDataSource: AgentToolDataSource) {
        self.toolDataSource = toolDataSource
        contextWindowUsage = AgentContextWindowUsage.empty(maximumTokens: model.contextSize)
    }

    var availabilityMessage: String {
        Self.availabilityMessage(for: model.availability)
    }

    deinit {
        contextUsageTask?.cancel()
    }

    func refreshContextWindowUsage(for draftText: String = "", debounce: Bool = false) {
        contextUsageTask?.cancel()
        contextUsageTask = Task { @MainActor [weak self] in
            if debounce {
                do {
                    try await Task.sleep(for: .milliseconds(220))
                } catch {
                    return
                }
            }
            await self?.updateContextWindowUsage(for: draftText)
        }
    }

    /// Warms the shared on-device model ahead of the first request. Call this
    /// when the agent UI appears so assets are loaded before the user submits.
    func prewarm() {
        guard model.isAvailable else { return }
        ensureSession(toolScope: .full).prewarm()
        refreshContextWindowUsage()
        AppLog.agent.debug("SystemLanguageModel prewarm requested at UI appear")
    }

    /// Drops the session and all conversation state for a fresh chat.
    func reset() {
        session = nil
        activeToolScope = nil
        contextMemory.reset()
        fallbackSessionTokens = 0
        contextWindowEvent = nil
        pendingOutcomeNote = nil
        guidedWorkflow = nil
        userContext = ""
        toolCallsThisTurn = 0
        toolCallCounts = [:]
        resetClarificationTracking()
        refreshContextWindowUsage()
        AppLog.agent.debug("Agent conversation engine reset")
    }

    /// Grounds the next turn: the model only proposed changes, so it needs to
    /// hear whether the user actually saved them.
    func noteDraftSaved() {
        pendingOutcomeNote = "The user saved the proposed changes."
        guidedWorkflow = nil
        contextMemory.recordOutcome(.saved)
        resetClarificationTracking()
        refreshSession(reason: "draftSaved")
        refreshContextWindowUsage()
    }

    func noteDraftCancelled() {
        pendingOutcomeNote = "The user cancelled the proposed changes."
        guidedWorkflow = nil
        contextMemory.recordOutcome(.cancelled)
        resetClarificationTracking()
        refreshSession(reason: "draftCancelled")
        refreshContextWindowUsage()
    }

    func send(_ message: String) async -> AgentRunResult {
        AppLog.agent.info("Agent turn requested messageCharacters=\(message.count, privacy: .public)")
        currentActivity = nil
        toolCallsThisTurn = 0
        toolCallCounts = [:]
        contextUsageTask?.cancel()
        defer { currentActivity = nil }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            appendUserContext(trimmed)
        }

        let snapshot = await localSnapshot()
        if var workflow = guidedWorkflow {
            let response = workflow.advance(trimmed, snapshot: snapshot, availabilityMessage: availabilityMessage)
            guidedWorkflow = response.workflow
            return await finalize(response.result, snapshot: snapshot, userMessage: trimmed)
        }

        if let response = AgentGuidedWorkflow.start(message: trimmed, snapshot: snapshot, availabilityMessage: availabilityMessage) {
            guidedWorkflow = response.workflow
            return await finalize(response.result, snapshot: snapshot, userMessage: trimmed)
        }

        guard model.isAvailable else {
            return await resultWithContextRefresh(unavailableResult())
        }

        let toolScope = AgentToolScope.infer(from: trimmed)
        let outboundPrompt = prompt(for: trimmed)
        await updateContextWindowUsage(promptText: outboundPrompt, toolScope: toolScope)
        do {
            let result = try await respondWithTimeout(to: outboundPrompt, condensed: false, toolScope: toolScope)
            return await finalize(result, snapshot: snapshot, userMessage: trimmed)
        } catch {
            if Self.isToolBudgetError(error) {
                return await resultWithContextRefresh(toolBudgetResult())
            }
            if error is AgentTurnTimeout {
                session = nil
                return await resultWithContextRefresh(timeoutResult())
            }
            guard Self.isContextWindowError(error) else {
                return await resultWithContextRefresh(failureResult(for: error, exceededContext: false))
            }

            // The on-device context window is small. Drop the full transcript
            // and retry once in a fresh session so long conversations recover.
            AppLog.agent.info("Agent context window exceeded; condensing conversation")
            refreshSession(reason: "contextOverflow")
            let condensed = condensedPrompt(for: trimmed)
            await updateContextWindowUsage(promptText: condensed, toolScope: toolScope)
            do {
                let result = try await respondWithTimeout(to: condensed, condensed: true, toolScope: toolScope)
                return await finalize(result, snapshot: snapshot, userMessage: trimmed)
            } catch {
                if Self.isToolBudgetError(error) {
                    return await resultWithContextRefresh(toolBudgetResult())
                }
                if error is AgentTurnTimeout {
                    session = nil
                    return await resultWithContextRefresh(timeoutResult())
                }
                return await resultWithContextRefresh(failureResult(for: error, exceededContext: Self.isContextWindowError(error)))
            }
        }
    }

    private func appendUserContext(_ message: String) {
        let lines = (userContext.split(separator: "\n").map(String.init) + [message])
            .suffix(Limits.userContextLines)
        userContext = lines.joined(separator: "\n")
    }

    private func finalize(_ result: AgentRunResult, snapshot: CRMDataSnapshot, userMessage: String) async -> AgentRunResult {
        let validated = AgentDraftValidator.validate(
            result,
            userContext: userContext,
            snapshot: snapshot,
            availabilityMessage: availabilityMessage
        )
        let guarded = applyClarificationGuard(to: validated)
        if !userMessage.isEmpty {
            contextMemory.recordUserMessage(userMessage)
        }
        contextMemory.record(guarded.result)

        if guarded.result.kind == .propose {
            refreshSession(reason: "draftPrepared")
        } else if guarded.stoppedLoop {
            refreshSession(reason: "clarificationLimit")
        } else if contextMemory.shouldRefreshSession {
            refreshSession(reason: "rollingWindow")
        }

        await updateContextWindowUsage()
        return guarded.result
    }

    private func resultWithContextRefresh(_ result: AgentRunResult) async -> AgentRunResult {
        await updateContextWindowUsage()
        return result
    }

    private func applyClarificationGuard(to result: AgentRunResult) -> (result: AgentRunResult, stoppedLoop: Bool) {
        guard result.kind == .clarify || result.draft.clarification != nil else {
            resetClarificationTracking()
            return (result, false)
        }

        consecutiveClarifications += 1

        if let key = clarificationKey(for: result) {
            if key == lastClarificationKey {
                repeatedClarificationCount += 1
            } else {
                lastClarificationKey = key
                repeatedClarificationCount = 0
            }
        } else {
            lastClarificationKey = nil
            repeatedClarificationCount = 0
        }

        if repeatedClarificationCount > Limits.repeatedClarificationRetries {
            AppLog.agent.info("Agent repeated clarification limit reached; forced final reply")
            return (terminalClarificationResult(from: result, reason: "Stopped the question round after the same clarification repeated."), true)
        }

        if consecutiveClarifications > Limits.consecutiveClarifications {
            AppLog.agent.info("Agent clarification limit reached; forced final reply")
            return (terminalClarificationResult(from: result, reason: "Stopped the question round after \(Limits.consecutiveClarifications) consecutive clarifications."), true)
        }

        return (result, false)
    }

    private func terminalClarificationResult(from result: AgentRunResult, reason: String) -> AgentRunResult {
        guidedWorkflow = nil
        resetClarificationTracking()

        var terminal = result
        terminal.kind = .reply
        terminal.message = "I'm going to stop the question loop here. I couldn't prepare a reliable draft from the details so far. Send the contact, opportunity, or follow-up plus the change in one message, or make the edit manually in the app."
        terminal.draft = .empty
        terminal.errorMessage = nil
        terminal.timeline.append(AgentTimelineItem(title: "Clarification limit reached", detail: reason, systemImage: "stop.circle"))
        return terminal
    }

    private func clarificationKey(for result: AgentRunResult) -> String? {
        let question = result.draft.clarification?.question.nilIfBlank ?? result.message.nilIfBlank
        return question?.searchKey.nilIfBlank
    }

    private func resetClarificationTracking() {
        consecutiveClarifications = 0
        lastClarificationKey = nil
        repeatedClarificationCount = 0
    }

    private func localSnapshot() async -> CRMDataSnapshot {
        do {
            return try await toolDataSource.snapshot()
        } catch {
            AppLog.agent.error("Agent local snapshot failed error=\(error.localizedDescription, privacy: .public)")
            return CRMDataSnapshot(contacts: [], opportunities: [], followUps: [])
        }
    }

    private func respondWithTimeout(to prompt: String, condensed: Bool, toolScope: AgentToolScope) async throws -> AgentRunResult {
        try await withThrowingTaskGroup(of: AgentRunResult.self) { group in
            group.addTask {
                let responseTask = Task { @MainActor in
                    try await self.respond(to: prompt, condensed: condensed, toolScope: toolScope)
                }
                return try await responseTask.value
            }
            group.addTask {
                try await Task.sleep(for: .seconds(Limits.turnTimeoutSeconds))
                throw AgentTurnTimeout()
            }

            guard let result = try await group.next() else {
                throw AgentTurnTimeout()
            }
            group.cancelAll()
            return result
        }
    }

    private func respond(to prompt: String, condensed: Bool, toolScope: AgentToolScope) async throws -> AgentRunResult {
        let session = ensureSession(toolScope: toolScope)
        await logContextBudget(prompt: prompt, toolScope: toolScope, condensed: condensed)

        // Greedy sampling makes extraction deterministic; temperature has no
        // effect under greedy, so it is intentionally omitted.
        let response = try await session.respond(
            to: prompt,
            generating: AgentTurn.self,
            includeSchemaInPrompt: false,
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: Limits.responseTokens)
        )

        pendingOutcomeNote = nil
        let turn = response.content
        let kind = turn.resolvedKind
        let timeline = timeline(from: response.transcriptEntries, thought: turn.thought, condensed: condensed)
        await refreshFallbackSessionTokens(session: session, prompt: prompt, turn: turn)

        AppLog.agent.info("Agent turn generated kind=\(kind.rawValue, privacy: .public) proposedChanges=\(turn.proposedChanges.count, privacy: .public) facts=\(turn.detectedFacts.count, privacy: .public) toolCalls=\(self.toolCallsThisTurn, privacy: .public)")
        return AgentRunResult(
            kind: kind,
            message: turn.message,
            thought: turn.thought,
            draft: turn.draft,
            timeline: timeline,
            availabilityMessage: availabilityMessage,
            errorMessage: nil
        )
    }

    private func ensureSession(toolScope: AgentToolScope) -> LanguageModelSession {
        if let session, activeToolScope == toolScope {
            return session
        }

        let reporting = reportingDataSource()
        let tools = toolScope.tools(dataSource: reporting)
        let instructions = Self.instructions(toolScope: toolScope)
        let session = LanguageModelSession(model: model, tools: tools, instructions: instructions)
        self.session = session
        activeToolScope = toolScope
        fallbackSessionTokens = Self.roughTokenCount(instructions) + tools.count * 90
        AppLog.agent.debug("Agent conversation session created scope=\(toolScope.rawValue, privacy: .public) tools=\(tools.count, privacy: .public)")
        return session
    }

    private func refreshFallbackSessionTokens(session: LanguageModelSession, prompt: String, turn: AgentTurn) async {
        do {
            fallbackSessionTokens = try await measuredTranscriptTokens(for: session.transcript)
        } catch {
            fallbackSessionTokens += Self.roughTokenCount(prompt) +
                Self.roughTokenCount(turn.message) +
                Self.roughTokenCount(turn.thought) +
                toolCallsThisTurn * 80
        }
    }

    /// Wraps the lookup data source so the UI can show which lookup the model
    /// is running and so the per-turn tool budget is enforced in one place.
    private func reportingDataSource() -> AgentToolDataSource {
        let base = toolDataSource
        return AgentToolDataSource(
            contacts: { query, limit in
                try await self.consumeToolBudget(activity: "findContacts \(query)")
                return try await base.contacts(query, limit)
            },
            opportunities: { query, limit in
                try await self.consumeToolBudget(activity: "findOpportunities \(query)")
                return try await base.opportunities(query, limit)
            },
            followUps: { query, limit in
                try await self.consumeToolBudget(activity: "findFollowUps \(query)")
                return try await base.followUps(query, limit)
            },
            snapshot: {
                try await self.consumeToolBudget(activity: "getPipelineSummary")
                return try await base.snapshot()
            }
        )
    }

    private func consumeToolBudget(activity: String) throws {
        toolCallsThisTurn += 1
        let key = activity.searchKey
        let count = (toolCallCounts[key] ?? 0) + 1
        toolCallCounts[key] = count

        guard count <= 1 else {
            AppLog.agent.warning("Agent repeated tool call blocked activity=\(activity, privacy: .private) calls=\(self.toolCallsThisTurn, privacy: .public)")
            throw AgentToolBudgetExceeded(reason: "Repeated local lookup blocked.")
        }

        guard toolCallsThisTurn <= Limits.toolCallsPerTurn else {
            AppLog.agent.warning("Agent tool budget exhausted calls=\(self.toolCallsThisTurn, privacy: .public)")
            throw AgentToolBudgetExceeded(reason: "Local lookup budget exhausted.")
        }
        currentActivity = activity
    }

    private func refreshSession(reason: String) {
        session = nil
        activeToolScope = nil
        fallbackSessionTokens = 0
        if let event = AgentContextWindowEvent.sessionRefresh(
            reason: reason,
            memoryTokens: contextMemory.estimatedTokenCount
        ) {
            contextWindowEvent = event
        }
        contextMemory.markSessionRefreshed()
        refreshContextWindowUsage()
        AppLog.agent.debug("Agent conversation session refreshed reason=\(reason, privacy: .public) memoryTokens=\(self.contextMemory.estimatedTokenCount, privacy: .public)")
    }

    private func updateContextWindowUsage(for draftText: String = "") async {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolScope = activeToolScope ?? AgentToolScope.infer(from: trimmed)
        await updateContextWindowUsage(promptText: prompt(for: trimmed), toolScope: toolScope)
    }

    private func updateContextWindowUsage(promptText: String, toolScope: AgentToolScope) async {
        let fallback = estimatedContextWindowUsage(promptText: promptText, toolScope: toolScope)
        do {
            let measured = try await measuredContextWindowUsage(promptText: promptText, toolScope: toolScope)
            guard !Task.isCancelled else { return }
            contextWindowUsage = measured
        } catch {
            guard !Task.isCancelled else { return }
            contextWindowUsage = fallback
            AppLog.agent.warning("Agent context token count failed scope=\(toolScope.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func measuredContextWindowUsage(promptText: String, toolScope: AgentToolScope) async throws -> AgentContextWindowUsage {
        let promptTokens = try await model.tokenCount(for: Prompt(promptText))
        let schemaTokens = try await model.tokenCount(for: AgentTurn.generationSchema)
        let memoryTokens = try await measuredMemoryTokens()
        let baseTokens: Int

        if let session, activeToolScope == toolScope {
            baseTokens = try await measuredTranscriptTokens(for: session.transcript)
        } else {
            let instructions = Instructions(Self.instructions(toolScope: toolScope))
            let tools = toolScope.tools(dataSource: toolDataSource)
            async let instructionsTokens = model.tokenCount(for: instructions)
            async let toolsTokens = model.tokenCount(for: tools)
            let countedInstructions = try await instructionsTokens
            let countedTools = try await toolsTokens
            baseTokens = countedInstructions + countedTools
        }

        return AgentContextWindowUsage(
            usedTokens: min(model.contextSize, baseTokens + promptTokens + schemaTokens),
            maximumTokens: model.contextSize,
            inputTokens: promptTokens,
            memoryTokens: memoryTokens,
            responseReserveTokens: Limits.responseTokens,
            toolScope: toolScope.rawValue,
            isEstimated: false
        )
    }

    /// Counts transcript entries with Apple's dedicated transcript token API.
    /// `Transcript` itself is a collection, so the full session transcript can
    /// be passed here without manually rebuilding entries.
    private func measuredTranscriptTokens<Entries: Collection>(
        for transcriptEntries: Entries
    ) async throws -> Int where Entries.Element == Transcript.Entry {
        try await model.tokenCount(for: transcriptEntries)
    }

    private func measuredMemoryTokens() async throws -> Int {
        guard let memory = contextMemory.promptPrefix() else { return 0 }
        return try await model.tokenCount(for: Prompt(memory))
    }

    private func estimatedContextWindowUsage(for draftText: String) -> AgentContextWindowUsage {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolScope = activeToolScope ?? AgentToolScope.infer(from: trimmed)
        return estimatedContextWindowUsage(promptText: prompt(for: trimmed), toolScope: toolScope)
    }

    private func estimatedContextWindowUsage(promptText: String, toolScope: AgentToolScope) -> AgentContextWindowUsage {
        let instructionsTokens = Self.roughTokenCount(Self.instructions(toolScope: toolScope)) + toolScope.toolCount * 90
        let sessionTokens = activeToolScope == toolScope && fallbackSessionTokens > 0 ? fallbackSessionTokens : instructionsTokens
        let inputTokens = Self.roughTokenCount(promptText)
        let schemaTokens = Self.roughTokenCount(AgentTurn.generationSchema.debugDescription)
        let usedTokens = min(model.contextSize, sessionTokens + inputTokens + schemaTokens)

        return AgentContextWindowUsage(
            usedTokens: usedTokens,
            maximumTokens: model.contextSize,
            inputTokens: inputTokens,
            memoryTokens: contextMemory.estimatedTokenCount,
            responseReserveTokens: Limits.responseTokens,
            toolScope: toolScope.rawValue,
            isEstimated: true
        )
    }

    private func logContextBudget(prompt: String, toolScope: AgentToolScope, condensed: Bool) async {
        let fallback = estimatedContextWindowUsage(promptText: prompt, toolScope: toolScope)
        let usage = (try? await measuredContextWindowUsage(promptText: prompt, toolScope: toolScope)) ?? fallback
        AppLog.agent.debug("Agent context budget contextSize=\(usage.maximumTokens, privacy: .public) usedTokens=\(usage.usedTokens, privacy: .public) inputTokens=\(usage.inputTokens, privacy: .public) memoryTokens=\(usage.memoryTokens, privacy: .public) responseLimit=\(usage.responseReserveTokens, privacy: .public) availableTokens=\(usage.availableTokens, privacy: .public) estimated=\(usage.isEstimated, privacy: .public) condensed=\(condensed, privacy: .public) scope=\(toolScope.rawValue, privacy: .public)")
    }

    private static func roughTokenCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, Int((Double(text.count) / 4.0).rounded(.up)))
    }

    private static func instructions(toolScope: AgentToolScope) -> String {
        return """
        You are LeadWhisper, a private on-device CRM assistant. Draft reviewable local CRM changes only; never save or claim saved.
        Today: \(Date.now.formatted(date: .numeric, time: .omitted)).
        Return one AgentTurn with thought. Use only user/tool facts; never invent records, IDs, contact data, budgets, dates, or notes.
        Tools: \(toolScope.instructionHint) Keep lookups short; do not repeat them. If records are missing or ambiguous, ask one focused question.
        Kinds: reply=short answer; clarify=one question, no changes; propose=reviewable changes.
        Before propose: createContact needs contactName+company; createOpportunity needs opportunityTitle+contactName/company; createFollowUp needs followUpTitle+contact/opportunity, dueDateText if given. Updates, completions, and deletes need one found local record with targetID=UUID.
        Stages: lead, qualified, proposalNeeded, proposalSent, won, lost. Follow-ups: open, done, archived.
        """
    }

    private func prompt(for message: String) -> String {
        var lines: [String] = []
        if let memory = contextMemory.promptPrefix() {
            lines.append(memory)
        }
        if let note = pendingOutcomeNote {
            lines.append("Note: \(note)")
        }
        if consecutiveClarifications >= Limits.consecutiveClarifications {
            lines.append("Note: you already asked \(consecutiveClarifications) questions in a row. Do not ask another clarification. Reply or propose using what you have.")
        }
        if repeatedClarificationCount >= Limits.repeatedClarificationRetries {
            lines.append("Note: you already repeated the same clarification. Do not ask that question again. Reply or propose using what you have.")
        }
        lines.append(message)
        return lines.joined(separator: "\n")
    }

    private func condensedPrompt(for message: String) -> String {
        var lines = ["Note: the earlier session exceeded the local model context window and was restarted with compact memory. Use the memory below only as continuity; ask for exact details if anything is missing."]
        if let memory = contextMemory.promptPrefix() {
            lines.append(memory)
        }
        if let note = pendingOutcomeNote {
            lines.append("Note: \(note)")
        }
        lines.append(message)
        return lines.joined(separator: "\n")
    }

    private func timeline(from entries: ArraySlice<Transcript.Entry>, thought: String, condensed: Bool) -> [AgentTimelineItem] {
        var items: [AgentTimelineItem] = []

        if condensed {
            items.append(AgentTimelineItem(title: "Context condensed", detail: "The conversation was restarted to fit the on-device model.", systemImage: "arrow.triangle.2.circlepath"))
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

    private func unavailableResult() -> AgentRunResult {
        AppLog.agent.info("Foundation Models unavailable availability=\(self.availabilityMessage, privacy: .public); no turn generated")
        return AgentRunResult(
            kind: .reply,
            message: "The on-device model is not available",
            thought: "",
            draft: .empty,
            timeline: [
                AgentTimelineItem(title: "Model unavailable", detail: availabilityMessage, systemImage: "exclamationmark.triangle")
            ],
            availabilityMessage: availabilityMessage,
            errorMessage: "LeadWhisper needs Apple Foundation Models to draft CRM changes. \(availabilityMessage) No local data was changed."
        )
    }

    private func toolBudgetResult() -> AgentRunResult {
        session = nil
        AppLog.agent.warning("Agent turn stopped after tool budget guard")
        return AgentRunResult(
            kind: .reply,
            message: "I stopped the lookup loop.",
            thought: "",
            draft: .empty,
            timeline: [
                AgentTimelineItem(title: "Lookup guard", detail: "The model repeated local lookups, so the turn was stopped before drafting changes.", systemImage: "stop.circle")
            ],
            availabilityMessage: availabilityMessage,
            errorMessage: "I could not prepare reliable CRM changes from that turn. Try naming the exact contact, opportunity, or follow-up."
        )
    }

    private func timeoutResult() -> AgentRunResult {
        AppLog.agent.warning("Agent turn timed out and session was reset")
        return AgentRunResult(
            kind: .reply,
            message: "I stopped that turn.",
            thought: "",
            draft: .empty,
            timeline: [
                AgentTimelineItem(title: "Turn timeout", detail: "The local model did not finish in time, so the session was reset.", systemImage: "timer")
            ],
            availabilityMessage: availabilityMessage,
            errorMessage: "The agent took too long to prepare a reliable answer. No local data was changed."
        )
    }

    private func failureResult(for error: Error, exceededContext: Bool) -> AgentRunResult {
        AppLog.agent.error("Agent turn failed contextWindow=\(exceededContext, privacy: .public) error=\(error.localizedDescription, privacy: .public)")

        let timeline = [
            AgentTimelineItem(title: "Foundation Model attempted", detail: "No CRM changes were drafted.", systemImage: "brain"),
            exceededContext
                ? AgentTimelineItem(title: "Could not draft changes", detail: "The request was too large for the local model.", systemImage: "exclamationmark.triangle")
                : AgentTimelineItem(title: "Model error", detail: error.localizedDescription, systemImage: "exclamationmark.triangle")
        ]

        return AgentRunResult(
            kind: .reply,
            message: "Could not draft changes",
            thought: "",
            draft: .empty,
            timeline: timeline,
            availabilityMessage: availabilityMessage,
            errorMessage: exceededContext ?
                "That request is too large for the local model. Try a shorter update, or reset the conversation." :
                "The local model could not prepare CRM changes. No local data was changed."
        )
    }

    static func isContextWindowError(_ error: Error) -> Bool {
        if let generationError = error as? LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = generationError {
                return true
            }
        }

        let message = error.localizedDescription.searchKey
        return message.contains("context window") || message.contains("model context")
    }

    static func isToolBudgetError(_ error: Error) -> Bool {
        if error is AgentToolBudgetExceeded {
            return true
        }

        let message = error.localizedDescription.searchKey
        return message.contains("tool budget") ||
            message.contains("lookup budget") ||
            message.contains("repeated local lookup")
    }

    static func availabilityMessage(for availability: SystemLanguageModel.Availability) -> String {
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
}

private enum AgentToolScope: String, Sendable {
    case none
    case contacts
    case opportunities
    case followUps
    case pipeline
    case full

    var toolCount: Int {
        toolNames.count
    }

    var instructionHint: String {
        switch self {
        case .none:
            "No lookup tools are attached; draft from user facts or clarify."
        case .contacts:
            "Use contact lookup only to identify/read an existing contact."
        case .opportunities:
            "Use opportunity lookup only to identify an existing opportunity."
        case .followUps:
            "Use follow-up lookup only to identify an existing task."
        case .pipeline:
            "Use pipeline summary for counts, workload, and due-date overview."
        case .full:
            "Use lookup tools only for exact existing records, pipeline facts, or disambiguation."
        }
    }

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

    static func infer(from message: String) -> AgentToolScope {
        let key = message.searchKey
        guard !key.isEmpty else { return .full }

        if isCreateIntent(key), !isExistingRecordMutation(key) {
            return .none
        }

        if isPipelineQuestion(key) {
            return .pipeline
        }

        if mentionsFollowUp(key) {
            return .followUps
        }

        if mentionsOpportunity(key) {
            return .opportunities
        }

        if mentionsContact(key) {
            return .contacts
        }

        return .full
    }

    private var toolNames: [String] {
        switch self {
        case .none:
            []
        case .contacts:
            ["findContacts", "getContactDetails"]
        case .opportunities:
            ["findOpportunities"]
        case .followUps:
            ["findFollowUps"]
        case .pipeline:
            ["getPipelineSummary"]
        case .full:
            ["findContacts", "findOpportunities", "findFollowUps", "getContactDetails", "getPipelineSummary"]
        }
    }

    private static func isCreateIntent(_ key: String) -> Bool {
        key.contains("create") ||
            key.contains("add contact") ||
            key.contains("add a contact") ||
            key.contains("add lead") ||
            key.contains("add a lead") ||
            key.contains("add opportunity") ||
            key.contains("add follow") ||
            key.contains("new contact") ||
            key.contains("new lead") ||
            key.contains("new opportunity") ||
            key.contains("anlegen") ||
            key.contains("erstell") ||
            key.contains("hinzufug") ||
            key.contains("neuer lead") ||
            key.contains("neuer kontakt") ||
            key.contains("neue chance") ||
            key.contains("neue opportunity")
    }

    private static func isExistingRecordMutation(_ key: String) -> Bool {
        key.contains("update") ||
            key.contains("change") ||
            key.contains("edit") ||
            key.contains("delete") ||
            key.contains("remove") ||
            key.contains("complete") ||
            key.contains("done") ||
            key.contains("archive") ||
            key.contains("stage") ||
            key.contains("won") ||
            key.contains("lost") ||
            key.contains("ander") ||
            key.contains("losch") ||
            key.contains("abschliess") ||
            key.contains("fertig")
    }

    private static func isPipelineQuestion(_ key: String) -> Bool {
        guard !isExistingRecordMutation(key) else { return false }
        return key.contains("pipeline") ||
            key.contains("summary") ||
            key.contains("overview") ||
            key.contains("status") ||
            key.contains("workload") ||
            key.contains("how many") ||
            key.contains("count") ||
            key.contains("today") ||
            key.contains("due") ||
            key.contains("uberblick") ||
            key.contains("faellig")
    }

    private static func mentionsFollowUp(_ key: String) -> Bool {
        key.contains("follow") ||
            key.contains("remind") ||
            key.contains("task") ||
            key.contains("todo") ||
            key.contains("nachfass") ||
            key.contains("erinner") ||
            key.contains("aufgabe")
    }

    private static func mentionsOpportunity(_ key: String) -> Bool {
        key.contains("opportunity") ||
            key.contains("deal") ||
            key.contains("proposal") ||
            key.contains("budget") ||
            key.contains("stage") ||
            key.contains("qualified") ||
            key.contains("won") ||
            key.contains("lost") ||
            key.contains("chance") ||
            key.contains("angebot")
    }

    private static func mentionsContact(_ key: String) -> Bool {
        key.contains("contact") ||
            key.contains("lead") ||
            key.contains("company") ||
            key.contains("email") ||
            key.contains("phone") ||
            key.contains("kontakt") ||
            key.contains("firma") ||
            key.contains("telefon")
    }
}

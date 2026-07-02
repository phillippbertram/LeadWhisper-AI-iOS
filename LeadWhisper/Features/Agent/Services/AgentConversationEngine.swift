import Foundation
import Observation
import OSLog

/// Runs the provider-backed agent chat loop while keeping memory, validation,
/// and review-before-save behavior in the app. Each turn follows the ReAct
/// pattern: the model records a thought,
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
        static let planningTokens = 120
        static let responseTokens = 900
    }

    /// Label for the lookup the model is running right now, shown live in the
    /// processing bubble while a turn is in flight.
    private(set) var currentActivity: String?
    private(set) var contextWindowUsage: AgentContextWindowUsage
    private(set) var contextWindowEvent: AgentContextWindowEvent?

    private let toolDataSource: AgentToolDataSource
    @ObservationIgnored private let modelRegistry: AgentModelClientRegistry
    @ObservationIgnored private var activeProviderKind: AgentProviderKind
    @ObservationIgnored private var contextMemory = AgentContextMemory()
    @ObservationIgnored private var pendingOutcomeNote: String?
    @ObservationIgnored private var userContext = ""
    @ObservationIgnored private var toolCallsThisTurn = 0
    @ObservationIgnored private var toolCallCounts: [String: Int] = [:]
    @ObservationIgnored private var consecutiveClarifications = 0
    @ObservationIgnored private var lastClarificationKey: String?
    @ObservationIgnored private var repeatedClarificationCount = 0
    @ObservationIgnored private var contextUsageTask: Task<Void, Never>?

    init(toolDataSource: AgentToolDataSource, modelRegistry: AgentModelClientRegistry) {
        self.toolDataSource = toolDataSource
        self.modelRegistry = modelRegistry
        let client = modelRegistry.selectedClient()
        activeProviderKind = client.providerKind
        contextWindowUsage = AgentContextWindowUsage.empty(maximumTokens: client.contextSize)
    }

    var availabilityMessage: String {
        modelRegistry.selectedClient().availabilityMessage
    }

    var providerKind: AgentProviderKind {
        modelRegistry.selectedClient().providerKind
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
        let client = selectedModelClient()
        client.prewarm(dataSource: toolDataSource)
        refreshContextWindowUsage()
    }

    /// Drops the session and all conversation state for a fresh chat.
    func reset() {
        selectedModelClient().resetSession()
        contextMemory.reset()
        contextWindowEvent = nil
        pendingOutcomeNote = nil
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
        contextMemory.recordOutcome(.saved)
        resetClarificationTracking()
        refreshSession(reason: "draftSaved")
        refreshContextWindowUsage()
    }

    func noteDraftCancelled() {
        pendingOutcomeNote = "The user cancelled the proposed changes."
        contextMemory.recordOutcome(.cancelled)
        resetClarificationTracking()
        refreshSession(reason: "draftCancelled")
        refreshContextWindowUsage()
    }

    func send(_ message: String) async -> AgentRunResult {
        AppLog.agent.info("Agent turn requested messageCharacters=\(message.count, privacy: .public)")
        let client = selectedModelClient()
        currentActivity = nil
        toolCallsThisTurn = 0
        toolCallCounts = [:]
        contextUsageTask?.cancel()
        defer { currentActivity = nil }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            appendUserContext(trimmed)
        }

        guard client.isAvailable else {
            return await resultWithContextRefresh(unavailableResult(client: client))
        }

        let outboundPrompt = prompt(for: trimmed)
        let toolPlan = await plannedTools(for: outboundPrompt, client: client)
        guard !Task.isCancelled else {
            return await resultWithContextRefresh(timeoutResult(client: client))
        }
        await updateContextWindowUsage(promptText: outboundPrompt, toolScope: toolPlan.toolScope)
        do {
            let result = try await respondWithTimeout(to: outboundPrompt, condensed: false, toolPlan: toolPlan, client: client)
            let snapshot = await localSnapshot()
            return await finalize(result, snapshot: snapshot, userMessage: trimmed)
        } catch {
            if Self.isToolBudgetError(error) {
                return await resultWithContextRefresh(toolBudgetResult())
            }
            if error is AgentTurnTimeout {
                client.resetSession()
                return await resultWithContextRefresh(timeoutResult(client: client))
            }
            guard client.isContextWindowError(error) else {
                return await resultWithContextRefresh(failureResult(for: error, exceededContext: false, client: client))
            }

            // The on-device context window is small. Drop the full transcript
            // and retry once in a fresh session so long conversations recover.
            AppLog.agent.info("Agent context window exceeded; condensing conversation")
            refreshSession(reason: "contextOverflow")
            let condensed = condensedPrompt(for: trimmed)
            await updateContextWindowUsage(promptText: condensed, toolScope: toolPlan.toolScope)
            do {
                let result = try await respondWithTimeout(to: condensed, condensed: true, toolPlan: toolPlan, client: client)
                let snapshot = await localSnapshot()
                return await finalize(result, snapshot: snapshot, userMessage: trimmed)
            } catch {
                if Self.isToolBudgetError(error) {
                    return await resultWithContextRefresh(toolBudgetResult())
                }
                if error is AgentTurnTimeout {
                    client.resetSession()
                    return await resultWithContextRefresh(timeoutResult(client: client))
                }
                return await resultWithContextRefresh(failureResult(for: error, exceededContext: client.isContextWindowError(error), client: client))
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

    private func respondWithTimeout(
        to prompt: String,
        condensed: Bool,
        toolPlan: AgentToolPlan,
        client: any AgentModelClient
    ) async throws -> AgentRunResult {
        let responseTask = Task { @MainActor in
            try await self.respond(to: prompt, condensed: condensed, toolPlan: toolPlan, client: client)
        }
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(Limits.turnTimeoutSeconds))
            responseTask.cancel()
        }

        do {
            let result = try await responseTask.value
            timeoutTask.cancel()
            return result
        } catch is CancellationError where responseTask.isCancelled {
            timeoutTask.cancel()
            throw AgentTurnTimeout()
        } catch {
            timeoutTask.cancel()
            throw error
        }
    }

    private func respond(to prompt: String, condensed: Bool, toolPlan: AgentToolPlan, client: any AgentModelClient) async throws -> AgentRunResult {
        let toolScope = toolPlan.toolScope
        await logContextBudget(prompt: prompt, toolScope: toolScope, condensed: condensed, client: client)
        let response = try await client.respond(
            to: AgentModelTurnRequest(
                prompt: prompt,
                condensed: condensed,
                toolScope: toolScope,
                instructions: Self.instructions(toolScope: toolScope),
                responseTokenLimit: Limits.responseTokens,
                maxToolCalls: Limits.toolCallsPerTurn,
                dataSource: reportingDataSource()
            )
        )
        pendingOutcomeNote = nil
        let turn = response.turn
        let kind = turn.resolvedKind

        AppLog.agent.info("Agent turn generated provider=\(client.providerKind.rawValue, privacy: .public) kind=\(kind.rawValue, privacy: .public) proposedChanges=\(turn.proposedChanges.count, privacy: .public) facts=\(turn.detectedFacts.count, privacy: .public) toolCalls=\(self.toolCallsThisTurn, privacy: .public)")
        var timeline = response.timeline
        timeline.insert(
            AgentTimelineItem(title: "Tool plan", detail: "\(toolPlan.toolScope.rawValue): \(toolPlan.reason)", systemImage: "point.3.connected.trianglepath.dotted"),
            at: 0
        )
        return AgentRunResult(
            kind: kind,
            message: turn.message,
            thought: turn.thought,
            draft: turn.draft,
            timeline: timeline,
            availabilityMessage: client.availabilityMessage,
            errorMessage: nil
        )
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

    private func plannedTools(for prompt: String, client: any AgentModelClient) async -> AgentToolPlan {
        do {
            let plan = try await client.planTools(
                for: AgentModelPlanRequest(
                    prompt: prompt,
                    instructions: Self.toolPlanningInstructions,
                    responseTokenLimit: Limits.planningTokens
                )
            )
            AppLog.agent.debug("Agent tool plan generated provider=\(client.providerKind.rawValue, privacy: .public) scope=\(plan.toolScope.rawValue, privacy: .public)")
            return plan
        } catch {
            AppLog.agent.warning("Agent tool planning failed provider=\(client.providerKind.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public); using full tools")
            return .fallback
        }
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
        selectedModelClient().resetSession()
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
        await updateContextWindowUsage(promptText: prompt(for: trimmed), toolScope: .full)
    }

    private func updateContextWindowUsage(promptText: String, toolScope: AgentToolScope) async {
        let client = selectedModelClient()
        let request = contextRequest(promptText: promptText, toolScope: toolScope)
        let fallback = client.estimatedContextWindowUsage(for: request)
        do {
            let measured = try await client.measuredContextWindowUsage(for: request)
            guard !Task.isCancelled else { return }
            contextWindowUsage = measured
        } catch {
            guard !Task.isCancelled else { return }
            contextWindowUsage = fallback
            AppLog.agent.warning("Agent context token count failed scope=\(toolScope.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func contextRequest(promptText: String, toolScope: AgentToolScope) -> AgentModelContextRequest {
        AgentModelContextRequest(
            promptText: promptText,
            instructions: Self.instructions(toolScope: toolScope),
            toolScope: toolScope,
            dataSource: toolDataSource,
            memoryPrompt: contextMemory.promptPrefix(),
            responseReserveTokens: Limits.responseTokens
        )
    }

    private func logContextBudget(prompt: String, toolScope: AgentToolScope, condensed: Bool, client: any AgentModelClient) async {
        let request = contextRequest(promptText: prompt, toolScope: toolScope)
        let fallback = client.estimatedContextWindowUsage(for: request)
        let usage = (try? await client.measuredContextWindowUsage(for: request)) ?? fallback
        AppLog.agent.debug("Agent context budget provider=\(client.providerKind.rawValue, privacy: .public) contextSize=\(usage.maximumTokens, privacy: .public) usedTokens=\(usage.usedTokens, privacy: .public) inputTokens=\(usage.inputTokens, privacy: .public) memoryTokens=\(usage.memoryTokens, privacy: .public) responseLimit=\(usage.responseReserveTokens, privacy: .public) availableTokens=\(usage.availableTokens, privacy: .public) estimated=\(usage.isEstimated, privacy: .public) condensed=\(condensed, privacy: .public) scope=\(toolScope.rawValue, privacy: .public)")
    }

    static func instructions(toolScope: AgentToolScope) -> String {
        return """
        You are LeadWhisper, a privacy-conscious CRM assistant. Draft reviewable local CRM changes only; never save or claim saved.
        Today: \(Date.now.formatted(date: .numeric, time: .omitted)).
        Return one AgentTurn with thought. Use only user/tool facts; never invent records, IDs, contact data, budgets, dates, or notes.
        Tools: \(toolScope.instructionHint) Keep lookups short; do not repeat them. If records are missing or ambiguous, ask one focused question.
        Kinds: reply=short answer; clarify=one question, no changes; propose=reviewable changes.
        Before propose: createContact needs contactName+company; createOpportunity needs opportunityTitle+contactName/company; createFollowUp needs followUpTitle+contact/opportunity, dueDateText if given. Updates, completions, and deletes need one found local record with targetID=UUID.
        Stages: lead, qualified, proposalNeeded, proposalSent, won, lost. Follow-ups: open, done, archived.
        """
    }

    private static var toolPlanningInstructions: String {
        """
        You are LeadWhisper's tool planner. Choose the smallest safe tool scope for the next CRM agent turn.
        Return one AgentToolPlan only.
        Scopes:
        - none: no existing CRM lookup is needed; the main agent can draft from user-provided facts or ask a clarification.
        - contacts: the next turn only needs contact search or contact details.
        - opportunities: the next turn only needs opportunity search.
        - followUps: the next turn only needs follow-up task search.
        - pipeline: the next turn only needs a CRM summary, counts, workload, or due-date overview.
        - full: multiple record types may be needed, the request is ambiguous, or the safe scope is unclear.
        Prefer full when uncertain. Do not solve the CRM task; only choose tool availability.
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
        var lines = ["Note: the earlier provider context window was exceeded and restarted with compact memory. Use the memory below only as continuity; ask for exact details if anything is missing."]
        if let memory = contextMemory.promptPrefix() {
            lines.append(memory)
        }
        if let note = pendingOutcomeNote {
            lines.append("Note: \(note)")
        }
        lines.append(message)
        return lines.joined(separator: "\n")
    }

    private func selectedModelClient() -> any AgentModelClient {
        let client = modelRegistry.selectedClient()
        if client.providerKind != activeProviderKind {
            AppLog.agent.info("Agent provider switched from=\(self.activeProviderKind.rawValue, privacy: .public) to=\(client.providerKind.rawValue, privacy: .public)")
            modelRegistry.client(for: activeProviderKind).resetSession()
            activeProviderKind = client.providerKind
            contextMemory.reset()
            contextWindowEvent = nil
            pendingOutcomeNote = nil
            userContext = ""
            resetClarificationTracking()
        }
        return client
    }

    private func unavailableResult(client: any AgentModelClient) -> AgentRunResult {
        AppLog.agent.info("Agent model unavailable provider=\(client.providerKind.rawValue, privacy: .public) availability=\(client.availabilityMessage, privacy: .public); no turn generated")
        return AgentRunResult(
            kind: .reply,
            message: "\(client.providerKind.displayName) is not available",
            thought: "",
            draft: .empty,
            timeline: [
                AgentTimelineItem(title: "Model unavailable", detail: client.availabilityMessage, systemImage: "exclamationmark.triangle")
            ],
            availabilityMessage: client.availabilityMessage,
            errorMessage: client.unavailableErrorMessage
        )
    }

    private func toolBudgetResult() -> AgentRunResult {
        selectedModelClient().resetSession()
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

    private func timeoutResult(client: any AgentModelClient) -> AgentRunResult {
        AppLog.agent.warning("Agent turn timed out and provider session was reset provider=\(client.providerKind.rawValue, privacy: .public)")
        return AgentRunResult(
            kind: .reply,
            message: "I stopped that turn.",
            thought: "",
            draft: .empty,
            timeline: [
                AgentTimelineItem(title: "Turn timeout", detail: "The selected model did not finish in time, so the session was reset.", systemImage: "timer")
            ],
            availabilityMessage: client.availabilityMessage,
            errorMessage: "The agent took too long to prepare a reliable answer. No local data was changed."
        )
    }

    private func failureResult(for error: Error, exceededContext: Bool, client: any AgentModelClient) -> AgentRunResult {
        AppLog.agent.error("Agent turn failed provider=\(client.providerKind.rawValue, privacy: .public) contextWindow=\(exceededContext, privacy: .public) error=\(error.localizedDescription, privacy: .public)")

        let timeline = [
            AgentTimelineItem(title: "\(client.providerKind.displayName) attempted", detail: "No CRM changes were drafted.", systemImage: "brain"),
            exceededContext
                ? AgentTimelineItem(title: "Could not draft changes", detail: "The request was too large for the selected model.", systemImage: "exclamationmark.triangle")
                : AgentTimelineItem(title: "Model error", detail: error.localizedDescription, systemImage: "exclamationmark.triangle")
        ]

        return AgentRunResult(
            kind: .reply,
            message: "Could not draft changes",
            thought: "",
            draft: .empty,
            timeline: timeline,
            availabilityMessage: client.availabilityMessage,
            errorMessage: exceededContext ?
                "That request is too large for the selected model. Try a shorter update, or reset the conversation." :
                "The selected model could not prepare CRM changes. No local data was changed."
        )
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
}

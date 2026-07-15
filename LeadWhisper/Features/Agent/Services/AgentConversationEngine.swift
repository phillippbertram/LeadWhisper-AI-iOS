import Foundation
import Observation
import OSLog
import SwiftAgentKit

/// App-facing orchestration around SwiftAgentKit. The SDK owns provider calls,
/// tool execution, session recovery, and runtime limits; this facade keeps the
/// CRM validation and review-before-save behavior local to LeadWhisper.
@MainActor
@Observable
final class AgentConversationEngine {
    private enum Limits {
        static let consecutiveClarifications = 3
        static let repeatedClarificationRetries = 1
        static let userContextLines = 8
    }

    var currentActivity: String? {
        activityRelay.currentActivity
    }

    private(set) var contextWindowUsage: AgentContextWindowUsage
    private(set) var contextWindowEvent: AgentContextWindowEvent?
    private(set) var availabilityMessage: String

    private let toolDataSource: AgentToolDataSource
    @ObservationIgnored private let agentFactory: LeadWhisperAgentFactory
    @ObservationIgnored private let activityRelay = AgentActivityRelay()
    @ObservationIgnored private var runtime: LeadWhisperAgentRuntime
    @ObservationIgnored private var pendingOutcomeNote: String?
    @ObservationIgnored private var userContext = ""
    @ObservationIgnored private var consecutiveClarifications = 0
    @ObservationIgnored private var lastClarificationKey: String?
    @ObservationIgnored private var repeatedClarificationCount = 0
    @ObservationIgnored private var contextUsageTask: Task<Void, Never>?

    init(toolDataSource: AgentToolDataSource, agentFactory: LeadWhisperAgentFactory) {
        self.toolDataSource = toolDataSource
        self.agentFactory = agentFactory
        let selectedProvider = AgentProviderKind.selected()
        let runtime = agentFactory.makeRuntime(
            providerKind: selectedProvider,
            dataSource: toolDataSource,
            activityRelay: activityRelay
        )
        self.runtime = runtime
        availabilityMessage = runtime.initialAvailability.message
        contextWindowUsage = .empty(maximumTokens: runtime.descriptor.contextWindow)
    }

    var providerKind: AgentProviderKind {
        runtime.providerKind
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

    func prewarm() {
        rebuildRuntimeIfProviderChanged()
        let runtime = runtime
        Task { @MainActor [weak self] in
            await runtime.agent.prewarm()
            let availability = await runtime.agent.availability()
            guard let self, self.runtime.providerKind == runtime.providerKind else { return }
            availabilityMessage = availability.message
            await updateContextWindowUsage()
        }
    }

    func reset() {
        contextUsageTask?.cancel()
        let oldRuntime = runtime
        runtime = agentFactory.makeRuntime(
            providerKind: AgentProviderKind.selected(),
            dataSource: toolDataSource,
            activityRelay: activityRelay
        )
        availabilityMessage = runtime.initialAvailability.message
        contextWindowUsage = .empty(maximumTokens: runtime.descriptor.contextWindow)
        contextWindowEvent = nil
        pendingOutcomeNote = nil
        userContext = ""
        activityRelay.reset()
        resetClarificationTracking()
        Task { await oldRuntime.agent.reset() }
        refreshContextWindowUsage()
        AppLog.agent.debug("Agent conversation engine reset")
    }

    func noteDraftSaved() {
        pendingOutcomeNote = "The user saved the proposed changes."
        let runtime = runtime
        Task { @MainActor [weak self] in
            await runtime.memory.recordOutcome(.saved)
            await self?.refreshSession(reason: "draftSaved", runtime: runtime)
        }
        resetClarificationTracking()
    }

    func noteDraftCancelled() {
        pendingOutcomeNote = "The user cancelled the proposed changes."
        let runtime = runtime
        Task { @MainActor [weak self] in
            await runtime.memory.recordOutcome(.cancelled)
            await self?.refreshSession(reason: "draftCancelled", runtime: runtime)
        }
        resetClarificationTracking()
    }

    func send(_ message: String) async -> AgentRunResult {
        rebuildRuntimeIfProviderChanged()
        let runtime = runtime
        activityRelay.reset()
        contextUsageTask?.cancel()

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLog.agent.info("Agent turn requested messageCharacters=\(trimmed.count, privacy: .public)")
        if !trimmed.isEmpty {
            appendUserContext(trimmed)
        }

        if let dueOverview = await dueOverviewResult(
            for: trimmed,
            availabilityMessage: availabilityMessage
        ) {
            return await finalizeLocalReply(dueOverview, userMessage: trimmed, runtime: runtime)
        }

        let availability = await runtime.agent.availability()
        availabilityMessage = availability.message
        guard availability.isAvailable else {
            return await resultWithContextRefresh(
                unavailableResult(availability: availability, providerKind: runtime.providerKind)
            )
        }

        await recordPendingContext(on: runtime)
        do {
            let run = try await runtime.agent.run(trimmed)
            contextWindowUsage = AgentContextWindowUsage(run.contextUsage)
            if run.condensed {
                contextWindowEvent = AgentContextWindowEvent.sessionRefresh(
                    reason: "contextOverflow",
                    memoryTokens: run.contextUsage.memoryTokens
                )
            }
            let result = result(from: run, runtime: runtime)
            let snapshot = await localSnapshot()
            return await finalize(result, snapshot: snapshot, userMessage: trimmed, runtime: runtime)
        } catch {
            if Self.isToolBudgetError(error) {
                return await resultWithContextRefresh(toolBudgetResult())
            }
            if case AgentRuntimeError.timeout = error {
                await runtime.agent.resetModelSession()
                return await resultWithContextRefresh(timeoutResult(providerKind: runtime.providerKind))
            }
            let exceededContext = await runtime.agent.model.classify(error) == .contextWindow
            return await resultWithContextRefresh(
                failureResult(
                    for: error,
                    exceededContext: exceededContext,
                    providerKind: runtime.providerKind
                )
            )
        }
    }

    private func rebuildRuntimeIfProviderChanged() {
        let selectedProvider = AgentProviderKind.selected()
        guard selectedProvider != runtime.providerKind else { return }

        let oldRuntime = runtime
        AppLog.agent.info("Agent provider switched from=\(oldRuntime.providerKind.rawValue, privacy: .public) to=\(selectedProvider.rawValue, privacy: .public)")
        runtime = agentFactory.makeRuntime(
            providerKind: selectedProvider,
            dataSource: toolDataSource,
            activityRelay: activityRelay
        )
        availabilityMessage = runtime.initialAvailability.message
        contextWindowUsage = .empty(maximumTokens: runtime.descriptor.contextWindow)
        contextWindowEvent = nil
        pendingOutcomeNote = nil
        userContext = ""
        activityRelay.reset()
        resetClarificationTracking()
        Task { await oldRuntime.agent.reset() }
    }

    private func recordPendingContext(on runtime: LeadWhisperAgentRuntime) async {
        if let pendingOutcomeNote {
            await runtime.agent.record(.system(pendingOutcomeNote))
            self.pendingOutcomeNote = nil
        }
        if consecutiveClarifications >= Limits.consecutiveClarifications {
            await runtime.agent.record(
                .system("You already asked \(consecutiveClarifications) questions in a row. Do not ask another clarification; reply or propose using what you have.")
            )
        }
        if repeatedClarificationCount >= Limits.repeatedClarificationRetries {
            await runtime.agent.record(
                .system("You already repeated the same clarification. Do not ask it again; reply or propose using what you have.")
            )
        }
    }

    private func result(
        from run: AgentRun<AgentTurn>,
        runtime: LeadWhisperAgentRuntime
    ) -> AgentRunResult {
        let turn = run.output
        let kind = turn.resolvedKind
        var timeline = timeline(from: run.events)
        if let thought = turn.thought.nilIfBlank {
            let thoughtItem = AgentTimelineItem(title: "Thought", detail: thought, systemImage: "brain")
            let insertionIndex = min(1, timeline.count)
            timeline.insert(thoughtItem, at: insertionIndex)
        }

        AppLog.agent.info("Agent turn generated provider=\(runtime.providerKind.rawValue, privacy: .public) kind=\(kind.rawValue, privacy: .public) proposedChanges=\(turn.proposedChanges.count, privacy: .public) facts=\(turn.detectedFacts.count, privacy: .public)")
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

    private func timeline(from events: [AgentEvent]) -> [AgentTimelineItem] {
        events.compactMap { event in
            switch event {
            case .toolSelection(let names, let reason):
                let scope = AgentToolScope.allCases.first { Set($0.toolNames) == Set(names) }?.rawValue ?? "custom"
                return AgentTimelineItem(
                    title: "Tool plan",
                    detail: "\(scope): \(reason)",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
            case .contextCondensed:
                return AgentTimelineItem(
                    title: "Context condensed",
                    detail: "The conversation was restarted to fit the selected model.",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            case .toolStarted(let name, let arguments):
                return AgentTimelineItem(
                    title: "Action",
                    detail: arguments == "{}" ? name : "\(name) \(arguments)",
                    systemImage: "wrench.and.screwdriver"
                )
            case .toolFinished(let name, let observation):
                return AgentTimelineItem(
                    title: "Observation",
                    detail: "\(name): \(observation)",
                    systemImage: "tray.full"
                )
            case .modelCompleted:
                return AgentTimelineItem(
                    title: "Final answer",
                    detail: "Structured AgentTurn received.",
                    systemImage: "checkmark.seal"
                )
            case .invocationStarted, .modelStarted, .invocationCompleted, .invocationFailed:
                return nil
            }
        }
    }

    private func finalize(
        _ result: AgentRunResult,
        snapshot: CRMDataSnapshot,
        userMessage: String,
        runtime: LeadWhisperAgentRuntime
    ) async -> AgentRunResult {
        let validated = AgentDraftValidator.validate(
            result,
            userContext: userContext,
            snapshot: snapshot,
            availabilityMessage: availabilityMessage
        )
        let guarded = applyClarificationGuard(to: validated)
        await runtime.memory.recordResultMetadata(guarded.result)

        if guarded.result.kind == .propose {
            await refreshSession(reason: "draftPrepared", runtime: runtime)
        } else if guarded.stoppedLoop {
            await refreshSession(reason: "clarificationLimit", runtime: runtime)
        } else if await runtime.memory.shouldRefreshSession {
            await refreshSession(reason: "rollingWindow", runtime: runtime)
        } else {
            await updateContextWindowUsage()
        }
        return guarded.result
    }

    private func finalizeLocalReply(
        _ result: AgentRunResult,
        userMessage: String,
        runtime: LeadWhisperAgentRuntime
    ) async -> AgentRunResult {
        if !userMessage.isEmpty {
            await runtime.memory.record(.user(userMessage))
        }
        await runtime.memory.record(.assistant(result.message))
        await runtime.memory.recordResultMetadata(result)

        if await runtime.memory.shouldRefreshSession {
            await refreshSession(reason: "rollingWindow", runtime: runtime)
        } else {
            await updateContextWindowUsage()
        }
        return result
    }

    private func resultWithContextRefresh(_ result: AgentRunResult) async -> AgentRunResult {
        await updateContextWindowUsage()
        return result
    }

    private func refreshSession(reason: String, runtime: LeadWhisperAgentRuntime) async {
        await runtime.agent.resetModelSession()
        let memoryTokens = await runtime.memory.estimatedTokenCount
        if let event = AgentContextWindowEvent.sessionRefresh(reason: reason, memoryTokens: memoryTokens) {
            contextWindowEvent = event
        }
        await runtime.memory.markSessionRefreshed()
        await updateContextWindowUsage()
        AppLog.agent.debug("Agent conversation session refreshed reason=\(reason, privacy: .public) memoryTokens=\(memoryTokens, privacy: .public)")
    }

    private func updateContextWindowUsage(for draftText: String = "") async {
        rebuildRuntimeIfProviderChanged()
        let usage = await runtime.agent.contextUsage(for: draftText)
        guard !Task.isCancelled else { return }
        contextWindowUsage = AgentContextWindowUsage(usage)
    }

    private func appendUserContext(_ message: String) {
        let lines = (userContext.split(separator: "\n").map(String.init) + [message])
            .suffix(Limits.userContextLines)
        userContext = lines.joined(separator: "\n")
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
            return (
                terminalClarificationResult(
                    from: result,
                    reason: "Stopped the question round after the same clarification repeated."
                ),
                true
            )
        }

        if consecutiveClarifications > Limits.consecutiveClarifications {
            AppLog.agent.info("Agent clarification limit reached; forced final reply")
            return (
                terminalClarificationResult(
                    from: result,
                    reason: "Stopped the question round after \(Limits.consecutiveClarifications) consecutive clarifications."
                ),
                true
            )
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
        terminal.timeline.append(
            AgentTimelineItem(
                title: "Clarification limit reached",
                detail: reason,
                systemImage: "stop.circle"
            )
        )
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

    private func dueOverviewResult(for userMessage: String, availabilityMessage: String) async -> AgentRunResult? {
        guard isDueOverviewQuestion(userMessage) else { return nil }

        let snapshot = await localSnapshot()
        let followUps = followUpOverviewItems(from: snapshot)
        return AgentRunResult(
            kind: .reply,
            message: followUpOverviewMessage(itemCount: followUps.count),
            thought: "Answered a follow-up due overview from the local CRM snapshot.",
            draft: .empty,
            timeline: [
                AgentTimelineItem(
                    title: "Local follow-up overview",
                    detail: "Read the local CRM snapshot and listed up to 3 open follow-ups. No changes were drafted.",
                    systemImage: "calendar.badge.clock"
                )
            ],
            availabilityMessage: availabilityMessage,
            errorMessage: nil,
            followUpOverviewItems: followUps
        )
    }

    private func isDueOverviewQuestion(_ message: String) -> Bool {
        let key = intentSearchKey(for: message)
        guard !key.isEmpty, !hasMutationIntent(key) else { return false }

        let phrases = [
            "due next", "due right now", "due today", "what is due", "what s due", "whats due",
            "what due", "due in my pipeline", "next follow up", "next follow ups", "open follow ups",
            "follow ups due", "follow up due", "was ist faellig", "was ist fallig", "was steht an",
            "was steht als naechstes an", "was steht als nachstes an", "naechste follow ups",
            "nachste follow ups", "naechste aufgaben", "nachste aufgaben"
        ]
        if phrases.contains(where: { key.contains($0) }) {
            return true
        }

        let tokens = Set(key.split(separator: " ").map(String.init))
        let hasDueToken = tokens.contains("due") || tokens.contains("faellig") ||
            tokens.contains("fallig") || tokens.contains("anstehend") || tokens.contains("offen")
        let overviewTokens: Set<String> = [
            "what", "next", "right", "now", "today", "pipeline", "follow", "followup", "followups",
            "was", "steht", "an", "naechste", "nachste", "aufgaben"
        ]
        return hasDueToken && !tokens.isDisjoint(with: overviewTokens)
    }

    private func hasMutationIntent(_ key: String) -> Bool {
        let mutationWords = [
            "mark", "complete", "done", "archive", "delete", "remove", "move", "create", "add",
            "update", "change", "edit", "revise", "save", "set", "finish", "close", "erledige",
            "erledigen", "abschliessen", "archivieren", "loeschen", "loschen", "verschiebe",
            "verschieben", "erstelle", "erstellen", "aendere", "andere", "bearbeite", "speichern", "setze"
        ]
        return mutationWords.contains { word in
            key == word || key.hasPrefix("\(word) ") || key.contains(" \(word) ") || key.hasSuffix(" \(word)")
        }
    }

    private func intentSearchKey(for message: String) -> String {
        let characters = message.searchKey.map { character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(characters).split(separator: " ").joined(separator: " ")
    }

    private func followUpOverviewItems(from snapshot: CRMDataSnapshot) -> [AgentFollowUpOverviewItem] {
        let openFollowUps = snapshot.followUps.filter { $0.state == FollowUpState.open.rawValue }
        let contactsByID = Dictionary(uniqueKeysWithValues: snapshot.contacts.map { ($0.id, $0.fullName) })
        let opportunitiesByID = Dictionary(uniqueKeysWithValues: snapshot.opportunities.map { ($0.id, $0.title) })

        return openFollowUps.prefix(3).compactMap { followUp in
            guard let id = UUID(uuidString: followUp.id) else { return nil }
            return AgentFollowUpOverviewItem(
                id: id,
                title: followUp.title,
                dueDateText: followUp.dueDateText.nilIfBlank ?? "No due date",
                contactTitle: followUp.contactID.flatMap { contactsByID[$0]?.nilIfBlank },
                opportunityTitle: followUp.opportunityID.flatMap { opportunitiesByID[$0]?.nilIfBlank }
            )
        }
    }

    private func followUpOverviewMessage(itemCount: Int) -> String {
        if itemCount == 0 { return "No open follow-ups are due right now." }
        if itemCount == 1 { return "Here is the next follow-up:" }
        return "Here are the next \(itemCount) follow-ups:"
    }

    private func unavailableResult(
        availability: AgentModelAvailability,
        providerKind: AgentProviderKind
    ) -> AgentRunResult {
        AppLog.agent.info("Agent model unavailable provider=\(providerKind.rawValue, privacy: .public) availability=\(availability.message, privacy: .public); no turn generated")
        return AgentRunResult(
            kind: .reply,
            message: "\(providerKind.displayName) is not available",
            thought: "",
            draft: .empty,
            timeline: [
                AgentTimelineItem(
                    title: "Model unavailable",
                    detail: availability.message,
                    systemImage: "exclamationmark.triangle"
                )
            ],
            availabilityMessage: availability.message,
            errorMessage: availability.unavailableMessage
        )
    }

    private func toolBudgetResult() -> AgentRunResult {
        AppLog.agent.warning("Agent turn stopped after tool budget guard")
        return AgentRunResult(
            kind: .reply,
            message: "I stopped the lookup loop.",
            thought: "",
            draft: .empty,
            timeline: [
                AgentTimelineItem(
                    title: "Lookup guard",
                    detail: "The model repeated local lookups, so the turn was stopped before drafting changes.",
                    systemImage: "stop.circle"
                )
            ],
            availabilityMessage: availabilityMessage,
            errorMessage: "I could not prepare reliable CRM changes from that turn. Try naming the exact contact, opportunity, or follow-up."
        )
    }

    private func timeoutResult(providerKind: AgentProviderKind) -> AgentRunResult {
        AppLog.agent.warning("Agent turn timed out and provider session was reset provider=\(providerKind.rawValue, privacy: .public)")
        return AgentRunResult(
            kind: .reply,
            message: "I stopped that turn.",
            thought: "",
            draft: .empty,
            timeline: [
                AgentTimelineItem(
                    title: "Turn timeout",
                    detail: "The selected model did not finish in time, so the session was reset.",
                    systemImage: "timer"
                )
            ],
            availabilityMessage: availabilityMessage,
            errorMessage: "The agent took too long to prepare a reliable answer. No local data was changed."
        )
    }

    private func failureResult(
        for error: Error,
        exceededContext: Bool,
        providerKind: AgentProviderKind
    ) -> AgentRunResult {
        AppLog.agent.error("Agent turn failed provider=\(providerKind.rawValue, privacy: .public) contextWindow=\(exceededContext, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        return AgentRunResult(
            kind: .reply,
            message: "Could not draft changes",
            thought: "",
            draft: .empty,
            timeline: [
                AgentTimelineItem(
                    title: "\(providerKind.displayName) attempted",
                    detail: "No CRM changes were drafted.",
                    systemImage: "brain"
                ),
                AgentTimelineItem(
                    title: exceededContext ? "Could not draft changes" : "Model error",
                    detail: exceededContext ? "The request was too large for the selected model." : error.localizedDescription,
                    systemImage: "exclamationmark.triangle"
                )
            ],
            availabilityMessage: availabilityMessage,
            errorMessage: exceededContext
                ? "That request is too large for the selected model. Try a shorter update, or reset the conversation."
                : "The selected model could not prepare CRM changes. No local data was changed."
        )
    }

    static func isToolBudgetError(_ error: Error) -> Bool {
        if case AgentRuntimeError.toolBudgetExceeded = error {
            return true
        }
        let message = error.localizedDescription.searchKey
        return message.contains("tool budget") ||
            message.contains("lookup budget") ||
            message.contains("repeated local lookup")
    }
}

private extension AgentContextWindowUsage {
    init(_ usage: AgentContextUsage) {
        self.init(
            usedTokens: usage.usedTokens,
            maximumTokens: usage.maximumTokens,
            inputTokens: usage.inputTokens,
            memoryTokens: usage.memoryTokens,
            responseReserveTokens: usage.responseReserveTokens,
            toolScope: usage.toolNames.isEmpty ? "none" : usage.toolNames.joined(separator: ","),
            isEstimated: usage.isEstimated
        )
    }
}

import Foundation
import FoundationModels
import OSLog

struct AgentLookupMode: OptionSet, Sendable, Equatable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let none: AgentLookupMode = []
    static let contacts = AgentLookupMode(rawValue: 1 << 0)
    static let opportunities = AgentLookupMode(rawValue: 1 << 1)
    static let followUps = AgentLookupMode(rawValue: 1 << 2)

    var label: String {
        if isEmpty {
            return "No local lookup"
        }

        var labels: [String] = []
        if contains(.contacts) { labels.append("contacts") }
        if contains(.opportunities) { labels.append("opportunities") }
        if contains(.followUps) { labels.append("follow-ups") }
        return labels.joined(separator: ", ")
    }
}

@MainActor
final class LeadAgentService {
    private let model = SystemLanguageModel.default
    private let toolDataSource: AgentToolDataSource

    init(repository _: CRMRepository, toolDataSource: AgentToolDataSource) {
        self.toolDataSource = toolDataSource
    }

    var availabilityMessage: String {
        Self.availabilityMessage(for: model.availability)
    }

    /// Warms the shared on-device model ahead of the first request. Call this when
    /// the agent UI appears so assets are loaded before the user submits a transcript.
    func prewarm() {
        guard model.isAvailable else { return }
        LanguageModelSession(model: model).prewarm()
        AppLog.agent.debug("SystemLanguageModel prewarm requested at UI appear")
    }

    func draft(for transcript: String) async -> AgentRunResult {
        AppLog.agent.info("Agent draft requested transcriptCharacters=\(transcript.count, privacy: .public)")

        let lookupMode = Self.lookupMode(for: transcript)
        AppLog.agent.info("Agent lookup mode=\(lookupMode.label, privacy: .public)")

        guard model.isAvailable else {
            AppLog.agent.info("Foundation Models unavailable availability=\(self.availabilityMessage, privacy: .public); no draft created")
            return AgentRunResult(
                draft: blockedDraft(summary: "Model unavailable"),
                timeline: [
                    AgentTimelineItem(title: "Transcript received", detail: "No CRM changes were drafted.", systemImage: "text.bubble"),
                    AgentTimelineItem(title: "Model unavailable", detail: availabilityMessage, systemImage: "exclamationmark.triangle")
                ],
                usedMockParser: false,
                availabilityMessage: availabilityMessage,
                errorMessage: "LeadWhisper needs Apple Foundation Models to draft CRM changes. No local data was changed."
            )
        }

        do {
            let selectedTools = tools(for: lookupMode)
            AppLog.agent.debug("Creating LanguageModelSession tools=\(selectedTools.count, privacy: .public) mode=\(lookupMode.label, privacy: .public)")
            let session = LanguageModelSession(
                model: model,
                tools: selectedTools,
                instructions: instructions(for: lookupMode)
            )

            // Greedy sampling makes extraction deterministic; temperature has no
            // effect under greedy, so it is intentionally omitted.
            let response = try await session.respond(
                to: prompt(for: transcript),
                generating: AgentDraft.self,
                includeSchemaInPrompt: false,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 1_200)
            )

            AppLog.agent.info("Foundation Models draft generated proposedChanges=\(response.content.proposedChanges.count, privacy: .public) facts=\(response.content.detectedFacts.count, privacy: .public) clarification=\(response.content.clarification == nil ? "none" : "present", privacy: .public)")
            return AgentRunResult(
                draft: response.content,
                timeline: timeline(from: response.transcriptEntries, lookupMode: lookupMode),
                usedMockParser: false,
                availabilityMessage: availabilityMessage,
                errorMessage: nil
            )
        } catch {
            let exceededContext = Self.isContextWindowError(error)
            AppLog.agent.error("Foundation Models draft failed contextWindow=\(exceededContext, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return AgentRunResult(
                draft: blockedDraft(summary: "Could not draft changes"),
                timeline: modelFailureTimeline(for: error, exceededContext: exceededContext, lookupMode: lookupMode),
                usedMockParser: false,
                availabilityMessage: availabilityMessage,
                errorMessage: exceededContext ?
                    "That request is too large for the local model. Try splitting it into one CRM update at a time." :
                    "The local model could not prepare CRM changes. No local data was changed."
            )
        }
    }

    private func instructions(for lookupMode: AgentLookupMode) -> String {
        let actions = ProposedChangeAction.allCases.map(\.rawValue).joined(separator: ", ")

        return """
        You are LeadWhisper, a local CRM planner. Return an AgentDraft only.
        Propose changes; never say data was saved.
        Never invent contacts, opportunities, follow-ups, IDs, companies, budgets, dates, phone numbers, emails, or notes.
        If the user's intent is not a clear CRM action, set clarification and leave proposedChanges empty.
        If any required information is missing or ambiguous, set clarification and leave proposedChanges empty.
        If a lookup tool says "No matching local records", treat that as a blocker. Ask what to create first or ask for a different existing record. Do not propose update, delete, complete, or archive changes for missing records.
        Required information:
        - createContact needs contactName and company.
        - updateContact needs exactly one existing contact or an explicit clarification.
        - createOpportunity needs contactName or company, opportunityTitle, and stage when the user names a stage.
        - updateOpportunity and updateOpportunityStage need exactly one existing opportunity.
        - createFollowUp needs a contact or opportunity plus followUpTitle; include dueDateText when the user provides timing.
        - updateFollowUp and completeFollowUp need exactly one existing follow-up.
        - delete actions need exactly one existing local record and targetID.
        Ask clarification when a name or record is ambiguous.
        Stages: lead, qualified, proposalNeeded, proposalSent, won, lost.
        Follow-up states: open, done, archived.
        Contact fields: full name, company, role, email, phone, notes, tags.
        Actions: \(actions).
        For destructive delete actions, use an existing local UUID in targetID and ask clarification unless exactly one record is clear.
        Attached lookup tools: \(lookupMode.label). Use short queries from the transcript only.
        """
    }

    private func prompt(for transcript: String) -> String {
        """
        Date: \(Date.now.formatted(date: .numeric, time: .omitted)).
        Transcript:
        \(transcript)
        """
    }

    private func tools(for lookupMode: AgentLookupMode) -> [any Tool] {
        var tools: [any Tool] = []
        if lookupMode.contains(.contacts) {
            tools.append(FindContactsTool(dataSource: toolDataSource))
        }
        if lookupMode.contains(.opportunities) {
            tools.append(FindOpportunitiesTool(dataSource: toolDataSource))
        }
        if lookupMode.contains(.followUps) {
            tools.append(FindFollowUpsTool(dataSource: toolDataSource))
        }
        return tools
    }

    private func timeline(from entries: ArraySlice<Transcript.Entry>, lookupMode: AgentLookupMode) -> [AgentTimelineItem] {
        var items: [AgentTimelineItem] = [
            AgentTimelineItem(title: "Transcript received", detail: "Sent compact request to Apple Foundation Models.", systemImage: "text.bubble"),
            AgentTimelineItem(title: "Lookup mode", detail: lookupMode.label, systemImage: "scope")
        ]

        for entry in entries {
            switch entry {
            case .toolCalls(let calls):
                for call in calls {
                    items.append(AgentTimelineItem(title: "Tool call", detail: call.toolName, systemImage: "wrench.and.screwdriver"))
                }
            case .toolOutput(let output):
                items.append(AgentTimelineItem(title: "Tool output", detail: output.toolName, systemImage: "tray.full"))
            case .response:
                items.append(AgentTimelineItem(title: "Draft generated", detail: "Structured AgentDraft received.", systemImage: "checkmark.seal"))
            case .prompt:
                items.append(AgentTimelineItem(title: "Prompt sent", detail: "The model received the CRM instruction.", systemImage: "arrow.up.message"))
            case .instructions:
                break
            @unknown default:
                items.append(AgentTimelineItem(title: "Transcript entry", detail: "Additional model event received.", systemImage: "ellipsis.message"))
            }
        }

        if !items.contains(where: { $0.title == "Draft generated" }) {
            items.append(AgentTimelineItem(title: "Draft generated", detail: "Structured AgentDraft received.", systemImage: "checkmark.seal"))
        }

        return items
    }

    private func blockedDraft(summary: String) -> AgentDraft {
        AgentDraft(
            summary: summary,
            detectedFacts: [],
            proposedChanges: [],
            clarification: nil,
            spokenConfirmation: ""
        )
    }

    private func modelFailureTimeline(for error: Error, exceededContext: Bool, lookupMode: AgentLookupMode) -> [AgentTimelineItem] {
        if exceededContext {
            return [
                AgentTimelineItem(title: "Foundation Model attempted", detail: "Compact lookup mode: \(lookupMode.label).", systemImage: "brain"),
                AgentTimelineItem(title: "Could not draft changes", detail: "The request was too large for the local model.", systemImage: "exclamationmark.triangle")
            ]
        }

        return [
            AgentTimelineItem(title: "Foundation Model attempted", detail: "No CRM changes were drafted.", systemImage: "brain"),
            AgentTimelineItem(title: "Model error", detail: error.localizedDescription, systemImage: "exclamationmark.triangle")
        ]
    }

    static func lookupMode(for transcript: String) -> AgentLookupMode {
        let key = transcript.searchKey

        if key.contains("neuer kontakt") || key.contains("new contact") {
            return .none
        }

        var mode: AgentLookupMode = .none

        if key.contains("delete") ||
            key.contains("remove") ||
            key.contains("lösche") ||
            key.contains("losche") ||
            key.contains("loesche")
        {
            if key.contains("contact") || key.contains("kontakt") {
                mode.insert(.contacts)
            } else if key.contains("opportunity") || key.contains("opportunitat") || key.contains("opportunität") {
                mode.insert(.opportunities)
            } else if key.contains("follow") || key.contains("task") || key.contains("aufgabe") {
                mode.insert(.followUps)
            } else {
                mode.insert(.contacts)
                mode.insert(.opportunities)
                mode.insert(.followUps)
            }
        }

        if key.contains("done") ||
            key.contains("complete") ||
            key.contains("erledigt")
        {
            mode.insert(.followUps)
        }

        if key.contains("email") ||
            key.contains("phone") ||
            key.contains("telefon") ||
            key.contains("role") ||
            key.contains("rolle")
        {
            mode.insert(.contacts)
        }

        if key.contains("verschiebe") ||
            key.contains("reschedule") ||
            key.contains("move follow") ||
            (key.contains("follow-up") && (key.contains("nachsten") || key.contains("next")))
        {
            mode.insert(.followUps)
        }

        if key.contains("verloren") ||
            key.contains("lost") ||
            key.contains("archiviere") ||
            key.contains("archive")
        {
            mode.insert(.opportunities)
            mode.insert(.followUps)
        }

        if key.contains("update") ||
            key.contains("edit") ||
            key.contains("bearbeite") ||
            key.contains("angebot positiv") ||
            key.contains("proposal sent") ||
            key.contains("angebot gesendet")
        {
            mode.insert(.contacts)
            mode.insert(.opportunities)
        }

        if key.contains("max") {
            mode.insert(.contacts)
            if !mode.contains(.followUps) {
                mode.insert(.opportunities)
            }
        }

        if key.contains("opportunity") || key.contains("opportunitat") {
            mode.insert(.opportunities)
        }

        return mode
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

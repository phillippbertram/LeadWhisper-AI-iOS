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

    var availabilityMessage: String {
        Self.availabilityMessage(for: model.availability)
    }

    func draft(for transcript: String, repository: CRMRepository) async -> AgentRunResult {
        AppLog.agent.info("Agent draft requested transcriptCharacters=\(transcript.count, privacy: .public)")

        let snapshot: CRMDataSnapshot
        do {
            snapshot = try repository.snapshot()
            AppLog.agent.debug("Agent snapshot loaded contacts=\(snapshot.contacts.count, privacy: .public) opportunities=\(snapshot.opportunities.count, privacy: .public) followUps=\(snapshot.followUps.count, privacy: .public)")
        } catch {
            AppLog.agent.error("Agent snapshot failed error=\(error.localizedDescription, privacy: .public)")
            let draft = DemoAgentParser.makeDraft(transcript: transcript)
            return AgentRunResult(
                draft: draft,
                timeline: [
                    AgentTimelineItem(title: "Transcript received", detail: "Using demo parser because local data could not be read.", systemImage: "text.bubble"),
                    AgentTimelineItem(title: "Repository error", detail: error.localizedDescription, systemImage: "exclamationmark.triangle")
                ],
                usedMockParser: true,
                availabilityMessage: availabilityMessage,
                errorMessage: error.localizedDescription
            )
        }

        let lookupMode = Self.lookupMode(for: transcript)
        AppLog.agent.info("Agent lookup mode=\(lookupMode.label, privacy: .public)")

        guard model.isAvailable else {
            AppLog.agent.info("Foundation Models unavailable availability=\(self.availabilityMessage, privacy: .public); using demo parser")
            let draft = DemoAgentParser.makeDraft(transcript: transcript, snapshot: snapshot)
            return AgentRunResult(
                draft: draft,
                timeline: [
                    AgentTimelineItem(title: "Transcript received", detail: "Foundation Models unavailable on this device.", systemImage: "text.bubble"),
                    AgentTimelineItem(title: "Demo parser used", detail: availabilityMessage, systemImage: "switch.2")
                ],
                usedMockParser: true,
                availabilityMessage: availabilityMessage,
                errorMessage: nil
            )
        }

        do {
            let selectedTools = tools(for: lookupMode, snapshot: snapshot)
            AppLog.agent.debug("Creating LanguageModelSession tools=\(selectedTools.count, privacy: .public) mode=\(lookupMode.label, privacy: .public)")
            let session = LanguageModelSession(
                model: model,
                tools: selectedTools,
                instructions: instructions(for: lookupMode)
            )

            session.prewarm()
            AppLog.agent.debug("LanguageModelSession prewarmed")

            let response = try await session.respond(
                to: prompt(for: transcript),
                generating: AgentDraft.self,
                includeSchemaInPrompt: false,
                options: GenerationOptions(sampling: .greedy, temperature: 0.1, maximumResponseTokens: 900)
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
            let draft = DemoAgentParser.makeDraft(transcript: transcript, snapshot: snapshot)
            return AgentRunResult(
                draft: draft,
                timeline: fallbackTimeline(for: error, exceededContext: exceededContext, lookupMode: lookupMode),
                usedMockParser: true,
                availabilityMessage: availabilityMessage,
                errorMessage: exceededContext ? nil : error.localizedDescription
            )
        }
    }

    private func instructions(for lookupMode: AgentLookupMode) -> String {
        """
        You are LeadWhisper, a local CRM planner. Return an AgentDraft only.
        Propose changes; never say data was saved. Ask clarification when a name or record is ambiguous.
        Stages: lead, qualified, proposalNeeded, proposalSent, won, lost.
        Actions: createContact, updateContact, createOpportunity, updateOpportunityStage, createInteraction, createFollowUp, updateFollowUp, archiveFollowUps.
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

    private func tools(for lookupMode: AgentLookupMode, snapshot: CRMDataSnapshot) -> [any Tool] {
        var tools: [any Tool] = []
        if lookupMode.contains(.contacts) {
            tools.append(FindContactsTool(contacts: snapshot.contacts))
        }
        if lookupMode.contains(.opportunities) {
            tools.append(FindOpportunitiesTool(opportunities: snapshot.opportunities))
        }
        if lookupMode.contains(.followUps) {
            tools.append(FindFollowUpsTool(followUps: snapshot.followUps))
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

    private func fallbackTimeline(for error: Error, exceededContext: Bool, lookupMode: AgentLookupMode) -> [AgentTimelineItem] {
        if exceededContext {
            return [
                AgentTimelineItem(title: "Foundation Model attempted", detail: "Compact lookup mode: \(lookupMode.label).", systemImage: "brain"),
                AgentTimelineItem(title: "Used compact fallback", detail: "Used compact fallback because the local model budget was exceeded.", systemImage: "switch.2")
            ]
        }

        return [
            AgentTimelineItem(title: "Foundation Model attempted", detail: "Fell back to demo parser.", systemImage: "brain"),
            AgentTimelineItem(title: "Model error", detail: error.localizedDescription, systemImage: "exclamationmark.triangle")
        ]
    }

    static func lookupMode(for transcript: String) -> AgentLookupMode {
        let key = transcript.searchKey

        if key.contains("neuer kontakt") || key.contains("new contact") {
            return .none
        }

        var mode: AgentLookupMode = .none

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
            "Apple Intelligence is not enabled. Demo parser is available."
        case .unavailable(.deviceNotEligible):
            "This device is not eligible for Apple Intelligence. Demo parser is available."
        case .unavailable(.modelNotReady):
            "The on-device model is not ready yet. Demo parser is available."
        @unknown default:
            "Foundation Models availability is unknown. Demo parser is available."
        }
    }
}

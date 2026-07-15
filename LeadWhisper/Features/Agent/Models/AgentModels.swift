import Foundation
import SwiftAgentKit

nonisolated enum AgentTurnKind: String, CaseIterable, Codable, Sendable, Hashable {
    case reply
    case clarify
    case propose
}

nonisolated struct AgentTurn: Codable, Sendable {
    var thought: String

    var kind: AgentTurnKind

    var message: String

    var clarification: ClarificationPrompt?

    var detectedFacts: [DetectedFact]

    var proposedChanges: [ProposedChange]
}

/// Reviewable proposal payload shown on result cards and applied by
/// `ChangeExecutor` after the user confirms. `AgentTurn` is the model wire
/// format; this struct is assembled from a turn or the demo parser.
struct AgentDraft: Sendable {
    var summary: String
    var detectedFacts: [DetectedFact]
    var proposedChanges: [ProposedChange]
    var clarification: ClarificationPrompt?
}

nonisolated struct DetectedFact: Codable, Sendable, Hashable {
    var kind: DetectedFactKind

    var value: String

    var detail: String
}

nonisolated enum DetectedFactKind: String, CaseIterable, Codable, Sendable, Hashable {
    case contact
    case company
    case opportunity
    case budget
    case stage
    case followUp
    case tag
    case note
    case startDate
}

nonisolated struct ProposedChange: Codable, Sendable, Identifiable {
    var id: String

    var action: ProposedChangeAction

    var title: String

    var targetID: String?

    var contactName: String?
    var company: String?
    var role: String?
    var email: String?
    var phone: String?
    var opportunityTitle: String?

    var stage: String?

    var estimatedValueEUR: Int?
    var budgetText: String?
    var expectedStart: String?
    var followUpTitle: String?
    var dueDateText: String?
    var followUpState: String?
    var notes: String?
    var tags: [String]
}

nonisolated enum ProposedChangeAction: String, CaseIterable, Codable, Sendable, Hashable {
    case createContact
    case updateContact
    case createOpportunity
    case updateOpportunity
    case updateOpportunityStage
    case createInteraction
    case createFollowUp
    case updateFollowUp
    case completeFollowUp
    case archiveFollowUps
    case deleteContact
    case deleteOpportunity
    case deleteFollowUp
}

nonisolated struct ClarificationPrompt: Codable, Sendable {
    var question: String

    var options: [String]

    var allowsFreeText: Bool?

    var placeholder: String?

    init(question: String, options: [String] = [], allowsFreeText: Bool? = nil, placeholder: String? = nil) {
        self.question = question
        self.options = options
        self.allowsFreeText = allowsFreeText
        self.placeholder = placeholder
    }
}

struct AgentRunResult: Identifiable {
    let id = UUID()
    var kind: AgentTurnKind
    var message: String
    var thought: String
    var draft: AgentDraft
    var timeline: [AgentTimelineItem]
    var availabilityMessage: String
    var errorMessage: String?
    var followUpOverviewItems: [AgentFollowUpOverviewItem] = []
    /// Old -> new field diffs per `ProposedChange.id`, resolved against the
    /// current local records when the result is shown for review.
    var diffs: [String: [ProposedChangeDiffField]] = [:]
}

struct AgentFollowUpOverviewItem: Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String
    var dueDateText: String
    var contactTitle: String?
    var opportunityTitle: String?

    var changedRecord: ChangedCRMRecord {
        ChangedCRMRecord(id: id, kind: .followUp, title: title)
    }
}

struct ProposedChangeDiffField: Identifiable, Hashable {
    let id = UUID()
    var title: String
    /// Current value of the targeted record; nil when unchanged or new.
    var oldValue: String?
    var newValue: String
}

/// UserDefaults keys for agent UI preferences.
enum AgentSettings {
    static let debugModeKey = "agentDebugModeEnabled"
    static let providerKindKey = "agentProviderKind"
}

struct AgentContextWindowUsage: Sendable, Hashable {
    var usedTokens: Int
    var maximumTokens: Int
    var inputTokens: Int
    var memoryTokens: Int
    var responseReserveTokens: Int
    var toolScope: String
    var isEstimated: Bool = false

    var availableTokens: Int {
        max(0, maximumTokens - usedTokens - responseReserveTokens)
    }

    var budgetedTokens: Int {
        min(maximumTokens, usedTokens + responseReserveTokens)
    }

    var fraction: Double {
        guard maximumTokens > 0 else { return 0 }
        return min(1, max(0, Double(budgetedTokens) / Double(maximumTokens)))
    }

    var percentage: Int {
        Int((fraction * 100).rounded())
    }

    var accessibilityValue: String {
        let prefix = isEstimated ? "Estimated " : ""
        return "\(prefix)\(percentage) percent, \(availableTokens) tokens available, \(usedTokens) of \(maximumTokens) tokens in context, \(responseReserveTokens) reserved for the next answer."
    }

    static func empty(maximumTokens: Int) -> AgentContextWindowUsage {
        AgentContextWindowUsage(
            usedTokens: 0,
            maximumTokens: maximumTokens,
            inputTokens: 0,
            memoryTokens: 0,
            responseReserveTokens: 0,
            toolScope: "full"
        )
    }
}

struct AgentContextWindowEvent: Identifiable, Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case condensed
        case refreshed
    }

    let id = UUID()
    var kind: Kind
    var title: String
    var detail: String
    var systemImage: String

    var accessibilityValue: String {
        "\(title). \(detail)"
    }

    static func sessionRefresh(reason: String, memoryTokens: Int) -> AgentContextWindowEvent? {
        switch reason {
        case "contextOverflow":
            AgentContextWindowEvent(
                kind: .condensed,
                title: "Compacted",
                detail: "Context window exceeded; a new session continued from compact memory. Memory tokens: \(memoryTokens).",
                systemImage: "arrow.triangle.2.circlepath"
            )
        case "rollingWindow":
            AgentContextWindowEvent(
                kind: .refreshed,
                title: "Refreshed",
                detail: "The chat continued in a fresh session from compact memory. Memory tokens: \(memoryTokens).",
                systemImage: "clock.arrow.circlepath"
            )
        default:
            nil
        }
    }
}

struct AgentTimelineItem: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var detail: String
    var systemImage: String
}

struct ChangeExecutionResult {
    var changedRecords: [ChangedCRMRecord]
}

struct ChangedCRMRecord: Identifiable, Hashable, Sendable {
    var id: UUID
    var kind: ActivityEntityKind
    var title: String
    var canOpen = true
}

enum AgentDraftError: LocalizedError {
    case clarificationRequired(String)
    case emptyDraft
    case destructiveConfirmationRequired
    case unsafeDestructiveChange(String)

    var errorDescription: String? {
        switch self {
        case .clarificationRequired(let question):
            "Clarification required: \(question)"
        case .emptyDraft:
            "The agent did not propose any changes."
        case .destructiveConfirmationRequired:
            "Deleting local CRM data requires an extra confirmation."
        case .unsafeDestructiveChange(let reason):
            reason
        }
    }
}

extension AgentTurn {
    static var outputSchema: AgentOutputSchema<AgentTurn> {
        AgentOutputSchema(name: "agent_turn", schema: schema)
    }

    static var schema: AgentSchema {
        .object(
            AgentSchema.Object(
                name: "AgentTurn",
                properties: [
                    .init(
                        "thought",
                        description: "One or two short sentences. Summarize the decision without hidden reasoning.",
                        schema: .string()
                    ),
                    .init("kind", schema: .string(allowedValues: AgentTurnKind.allCases.map(\.rawValue))),
                    .init("message", description: "Short user-visible message.", schema: .string()),
                    .init("clarification", schema: .nullable(clarificationSchema), isOptional: true),
                    .init("detectedFacts", schema: .array(items: detectedFactSchema, maximumCount: 6)),
                    .init("proposedChanges", schema: .array(items: proposedChangeSchema, maximumCount: 6))
                ]
            )
        )
    }

    private static var detectedFactSchema: AgentSchema {
        .object(
            AgentSchema.Object(
                name: "DetectedFact",
                properties: [
                    .init("kind", schema: .string(allowedValues: DetectedFactKind.allCases.map(\.rawValue))),
                    .init("value", schema: .string()),
                    .init("detail", description: "Short source or reason.", schema: .string())
                ]
            )
        )
    }

    private static var clarificationSchema: AgentSchema {
        .object(
            AgentSchema.Object(
                name: "ClarificationPrompt",
                properties: [
                    .init("question", schema: .string()),
                    .init("options", schema: .array(items: .string(), maximumCount: 4)),
                    .init("allowsFreeText", schema: .nullable(.boolean()), isOptional: true),
                    .init("placeholder", schema: .nullable(.string()), isOptional: true)
                ]
            )
        )
    }

    private static var proposedChangeSchema: AgentSchema {
        .object(
            AgentSchema.Object(
                name: "ProposedChange",
                properties: [
                    .init("id", schema: .string()),
                    .init("action", schema: .string(allowedValues: ProposedChangeAction.allCases.map(\.rawValue))),
                    .init("title", schema: .string()),
                    .init("targetID", description: "Existing local UUID.", schema: .nullable(.string()), isOptional: true),
                    .init("contactName", schema: .nullable(.string()), isOptional: true),
                    .init("company", schema: .nullable(.string()), isOptional: true),
                    .init("role", schema: .nullable(.string()), isOptional: true),
                    .init("email", schema: .nullable(.string()), isOptional: true),
                    .init("phone", schema: .nullable(.string()), isOptional: true),
                    .init("opportunityTitle", schema: .nullable(.string()), isOptional: true),
                    .init("stage", schema: .nullable(.string(allowedValues: ["lead", "qualified", "proposalNeeded", "proposalSent", "won", "lost"])), isOptional: true),
                    .init("estimatedValueEUR", schema: .nullable(.integer()), isOptional: true),
                    .init("budgetText", schema: .nullable(.string()), isOptional: true),
                    .init("expectedStart", schema: .nullable(.string()), isOptional: true),
                    .init("followUpTitle", schema: .nullable(.string()), isOptional: true),
                    .init("dueDateText", schema: .nullable(.string()), isOptional: true),
                    .init("followUpState", schema: .nullable(.string(allowedValues: ["open", "done", "archived"])), isOptional: true),
                    .init("notes", schema: .nullable(.string()), isOptional: true),
                    .init("tags", schema: .array(items: .string(), maximumCount: 5))
                ]
            )
        )
    }

    /// Trusts the generated content over the declared kind so a mislabeled
    /// turn still renders safely.
    var resolvedKind: AgentTurnKind {
        if clarification != nil {
            return .clarify
        }
        if !proposedChanges.isEmpty {
            return .propose
        }
        return .reply
    }

    var draft: AgentDraft {
        AgentDraft(
            summary: message,
            detectedFacts: detectedFacts,
            proposedChanges: proposedChanges,
            clarification: clarification
        )
    }
}

extension AgentDraft {
    var canApply: Bool {
        clarification == nil && !proposedChanges.isEmpty
    }

    var containsDestructiveChange: Bool {
        proposedChanges.contains { $0.action.isDestructive }
    }

    static var empty: AgentDraft {
        AgentDraft(
            summary: "",
            detectedFacts: [],
            proposedChanges: [],
            clarification: nil
        )
    }
}

extension ProposedChange {
    init(
        action: ProposedChangeAction,
        title: String,
        targetID: String? = nil,
        contactName: String? = nil,
        company: String? = nil,
        role: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        opportunityTitle: String? = nil,
        stage: String? = nil,
        estimatedValueEUR: Int? = nil,
        budgetText: String? = nil,
        expectedStart: String? = nil,
        followUpTitle: String? = nil,
        dueDateText: String? = nil,
        followUpState: String? = nil,
        notes: String? = nil,
        tags: [String] = []
    ) {
        self.id = UUID().uuidString
        self.action = action
        self.title = title
        self.targetID = targetID
        self.contactName = contactName
        self.company = company
        self.role = role
        self.email = email
        self.phone = phone
        self.opportunityTitle = opportunityTitle
        self.stage = stage
        self.estimatedValueEUR = estimatedValueEUR
        self.budgetText = budgetText
        self.expectedStart = expectedStart
        self.followUpTitle = followUpTitle
        self.dueDateText = dueDateText
        self.followUpState = followUpState
        self.notes = notes
        self.tags = tags
    }
}

extension ProposedChangeAction {
    var isDestructive: Bool {
        switch self {
        case .deleteContact, .deleteOpportunity, .deleteFollowUp:
            true
        case .createContact, .updateContact, .createOpportunity, .updateOpportunity, .updateOpportunityStage, .createInteraction, .createFollowUp, .updateFollowUp, .completeFollowUp, .archiveFollowUps:
            false
        }
    }
}

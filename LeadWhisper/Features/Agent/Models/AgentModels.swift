import Foundation
import FoundationModels

@Generable
enum AgentTurnKind: String, Codable, Sendable, Hashable {
    case reply
    case clarify
    case propose
}

@Generable
struct AgentTurn: Codable, Sendable {
    @Guide(description: "One or two short sentences.")
    var thought: String

    var kind: AgentTurnKind

    @Guide(description: "Short user-visible message.")
    var message: String

    var clarification: ClarificationPrompt?

    @Guide(.maximumCount(6))
    var detectedFacts: [DetectedFact]

    @Guide(.maximumCount(6))
    var proposedChanges: [ProposedChange]

    var spokenConfirmation: String?
}

/// Reviewable proposal payload shown on result cards and applied by
/// `ChangeExecutor` after the user confirms. `AgentTurn` is the model wire
/// format; this struct is assembled from a turn or the demo parser.
struct AgentDraft: Sendable {
    var summary: String
    var detectedFacts: [DetectedFact]
    var proposedChanges: [ProposedChange]
    var clarification: ClarificationPrompt?
    var spokenConfirmation: String
}

@Generable
struct DetectedFact: Codable, Sendable, Hashable {
    var kind: DetectedFactKind

    var value: String

    @Guide(description: "Short source or reason.")
    var detail: String
}

@Generable
enum DetectedFactKind: String, Codable, Sendable, Hashable {
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

@Generable
struct ProposedChange: Codable, Sendable, Identifiable {
    var id: String

    var action: ProposedChangeAction

    var title: String

    @Guide(description: "Existing local UUID.")
    var targetID: String?

    var contactName: String?
    var company: String?
    var role: String?
    var email: String?
    var phone: String?
    var opportunityTitle: String?

    @Guide(description: "lead, qualified, proposalNeeded, proposalSent, won, lost.")
    var stage: String?

    var estimatedValueEUR: Int?
    var budgetText: String?
    var expectedStart: String?
    var followUpTitle: String?
    var dueDateText: String?
    @Guide(description: "open, done, archived.")
    var followUpState: String?
    var notes: String?
    @Guide(.maximumCount(5))
    var tags: [String]
}

@Generable
enum ProposedChangeAction: String, CaseIterable, Codable, Sendable, Hashable {
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

@Generable
struct ClarificationPrompt: Codable, Sendable {
    var question: String

    @Guide(.maximumCount(4))
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
    /// Old -> new field diffs per `ProposedChange.id`, resolved against the
    /// current local records when the result is shown for review.
    var diffs: [String: [ProposedChangeDiffField]] = [:]
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
    var spokenSummary: String
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
    static var openAIJSONSchema: JSONValue {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "thought": .object([
                    "type": .string("string"),
                    "description": .string("One or two short sentences. Do not include private hidden reasoning; summarize the decision briefly.")
                ]),
                "kind": .object([
                    "type": .string("string"),
                    "enum": .stringArray([AgentTurnKind.reply.rawValue, AgentTurnKind.clarify.rawValue, AgentTurnKind.propose.rawValue])
                ]),
                "message": .object([
                    "type": .string("string"),
                    "description": .string("Short user-visible message.")
                ]),
                "clarification": clarificationSchema,
                "detectedFacts": .object([
                    "type": .string("array"),
                    "maxItems": .number(6),
                    "items": detectedFactSchema
                ]),
                "proposedChanges": .object([
                    "type": .string("array"),
                    "maxItems": .number(6),
                    "items": proposedChangeSchema
                ]),
                "spokenConfirmation": .nullableString()
            ]),
            "required": .stringArray(["thought", "kind", "message", "clarification", "detectedFacts", "proposedChanges", "spokenConfirmation"])
        ])
    }

    private static var detectedFactSchema: JSONValue {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "kind": .object([
                    "type": .string("string"),
                    "enum": .stringArray([
                        DetectedFactKind.contact.rawValue,
                        DetectedFactKind.company.rawValue,
                        DetectedFactKind.opportunity.rawValue,
                        DetectedFactKind.budget.rawValue,
                        DetectedFactKind.stage.rawValue,
                        DetectedFactKind.followUp.rawValue,
                        DetectedFactKind.tag.rawValue,
                        DetectedFactKind.note.rawValue,
                        DetectedFactKind.startDate.rawValue
                    ])
                ]),
                "value": .object(["type": .string("string")]),
                "detail": .object(["type": .string("string")])
            ]),
            "required": .stringArray(["kind", "value", "detail"])
        ])
    }

    private static var clarificationSchema: JSONValue {
        .object([
            "type": .array([.string("object"), .string("null")]),
            "additionalProperties": .bool(false),
            "properties": .object([
                "question": .object(["type": .string("string")]),
                "options": .object([
                    "type": .string("array"),
                    "maxItems": .number(4),
                    "items": .object(["type": .string("string")])
                ]),
                "allowsFreeText": .nullableBoolean(),
                "placeholder": .nullableString()
            ]),
            "required": .stringArray(["question", "options", "allowsFreeText", "placeholder"])
        ])
    }

    private static var proposedChangeSchema: JSONValue {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "action": .object([
                    "type": .string("string"),
                    "enum": .stringArray(ProposedChangeAction.allCases.map(\.rawValue))
                ]),
                "title": .object(["type": .string("string")]),
                "targetID": .nullableString(description: "Existing local UUID for updates and destructive changes."),
                "contactName": .nullableString(),
                "company": .nullableString(),
                "role": .nullableString(),
                "email": .nullableString(),
                "phone": .nullableString(),
                "opportunityTitle": .nullableString(),
                "stage": .object([
                    "type": .array([.string("string"), .string("null")]),
                    "enum": .array([
                        .string("lead"),
                        .string("qualified"),
                        .string("proposalNeeded"),
                        .string("proposalSent"),
                        .string("won"),
                        .string("lost"),
                        .null
                    ])
                ]),
                "estimatedValueEUR": .nullableInteger(),
                "budgetText": .nullableString(),
                "expectedStart": .nullableString(),
                "followUpTitle": .nullableString(),
                "dueDateText": .nullableString(),
                "followUpState": .object([
                    "type": .array([.string("string"), .string("null")]),
                    "enum": .array([
                        .string("open"),
                        .string("done"),
                        .string("archived"),
                        .null
                    ])
                ]),
                "notes": .nullableString(),
                "tags": .object([
                    "type": .string("array"),
                    "maxItems": .number(5),
                    "items": .object(["type": .string("string")])
                ])
            ]),
            "required": .stringArray([
                "id",
                "action",
                "title",
                "targetID",
                "contactName",
                "company",
                "role",
                "email",
                "phone",
                "opportunityTitle",
                "stage",
                "estimatedValueEUR",
                "budgetText",
                "expectedStart",
                "followUpTitle",
                "dueDateText",
                "followUpState",
                "notes",
                "tags"
            ])
        ])
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
            clarification: clarification,
            spokenConfirmation: spokenConfirmation ?? ""
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
            clarification: nil,
            spokenConfirmation: ""
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

import Foundation
import FoundationModels

@Generable
enum AgentTurnKind: String, Sendable, Hashable {
    case reply
    case clarify
    case propose
}

@Generable
struct AgentTurn: Sendable {
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
struct DetectedFact: Sendable, Hashable {
    var kind: DetectedFactKind

    var value: String

    @Guide(description: "Short source or reason.")
    var detail: String
}

@Generable
enum DetectedFactKind: String, Sendable, Hashable {
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
struct ProposedChange: Sendable, Identifiable {
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
enum ProposedChangeAction: String, CaseIterable, Sendable, Hashable {
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
struct ClarificationPrompt: Sendable {
    var question: String

    @Guide(.minimumCount(2), .maximumCount(4))
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
}

struct AgentContextWindowUsage: Sendable, Hashable {
    var usedTokens: Int
    var maximumTokens: Int
    var inputTokens: Int
    var memoryTokens: Int
    var responseReserveTokens: Int
    var toolScope: String

    var fraction: Double {
        guard maximumTokens > 0 else { return 0 }
        return min(1, max(0, Double(usedTokens) / Double(maximumTokens)))
    }

    var percentage: Int {
        Int((fraction * 100).rounded())
    }

    var accessibilityValue: String {
        "Estimated \(percentage) percent, \(usedTokens) of \(maximumTokens) tokens."
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

struct AgentTimelineItem: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var detail: String
    var systemImage: String
}

struct ChangeExecutionResult {
    var spokenSummary: String
    var changedTitles: [String]
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

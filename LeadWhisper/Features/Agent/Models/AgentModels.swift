import Foundation
import FoundationModels

@Generable(description: "CRM change draft.")
struct AgentDraft: Sendable {
    @Guide(description: "Short request summary.")
    var summary: String

    @Guide(description: "Detected facts.")
    var detectedFacts: [DetectedFact]

    @Guide(description: "Planned CRM changes.")
    var proposedChanges: [ProposedChange]

    @Guide(description: "Question when ambiguous; nil when safe.")
    var clarification: ClarificationPrompt?

    @Guide(description: "Brief confirmation after save.")
    var spokenConfirmation: String
}

@Generable(description: "Extracted fact.")
struct DetectedFact: Sendable, Hashable {
    @Guide(description: "Kind of extracted CRM fact.")
    var kind: DetectedFactKind

    @Guide(description: "Human value.")
    var value: String

    @Guide(description: "Short source or reason.")
    var detail: String
}

@Generable(description: "Kind of extracted CRM fact.")
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

@Generable(description: "Proposed CRM mutation.")
struct ProposedChange: Sendable, Identifiable {
    var id: String

    @Guide(description: "Allowed CRM mutation action.")
    var action: ProposedChangeAction

    @Guide(description: "Card title.")
    var title: String

    @Guide(description: "Existing local UUID if found.")
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
    var tags: [String]
}

@Generable(description: "Allowed CRM mutation action.")
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

@Generable(description: "Clarification question.")
struct ClarificationPrompt: Sendable {
    @Guide(description: "Question.")
    var question: String

    @Guide(description: "Concrete options.")
    var options: [String]
}

struct AgentRunResult: Identifiable {
    let id = UUID()
    var draft: AgentDraft
    var timeline: [AgentTimelineItem]
    var usedMockParser: Bool
    var availabilityMessage: String
    var errorMessage: String?
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

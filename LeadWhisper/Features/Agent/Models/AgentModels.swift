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
struct DetectedFact: Sendable {
    @Guide(description: "contact, company, opportunity, budget, stage, followUp, tag, note, startDate.")
    var kind: String

    @Guide(description: "Human value.")
    var value: String

    @Guide(description: "Short source or reason.")
    var detail: String
}

@Generable(description: "Proposed CRM mutation.")
struct ProposedChange: Sendable, Identifiable {
    var id: String

    @Guide(description: "createContact, updateContact, createOpportunity, updateOpportunityStage, createInteraction, createFollowUp, updateFollowUp, archiveFollowUps.")
    var action: String

    @Guide(description: "Card title.")
    var title: String

    @Guide(description: "Existing local UUID if found.")
    var targetID: String?

    var contactName: String?
    var company: String?
    var opportunityTitle: String?

    @Guide(description: "lead, qualified, proposalNeeded, proposalSent, won, lost.")
    var stage: String?

    var estimatedValueEUR: Int?
    var budgetText: String?
    var expectedStart: String?
    var followUpTitle: String?
    var dueDateText: String?
    var notes: String?
    var tags: [String]
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

    var errorDescription: String? {
        switch self {
        case .clarificationRequired(let question):
            "Clarification required: \(question)"
        case .emptyDraft:
            "The agent did not propose any changes."
        }
    }
}

extension AgentDraft {
    var canApply: Bool {
        clarification == nil && !proposedChanges.isEmpty
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
        action: String,
        title: String,
        targetID: String? = nil,
        contactName: String? = nil,
        company: String? = nil,
        opportunityTitle: String? = nil,
        stage: String? = nil,
        estimatedValueEUR: Int? = nil,
        budgetText: String? = nil,
        expectedStart: String? = nil,
        followUpTitle: String? = nil,
        dueDateText: String? = nil,
        notes: String? = nil,
        tags: [String] = []
    ) {
        self.id = UUID().uuidString
        self.action = action
        self.title = title
        self.targetID = targetID
        self.contactName = contactName
        self.company = company
        self.opportunityTitle = opportunityTitle
        self.stage = stage
        self.estimatedValueEUR = estimatedValueEUR
        self.budgetText = budgetText
        self.expectedStart = expectedStart
        self.followUpTitle = followUpTitle
        self.dueDateText = dueDateText
        self.notes = notes
        self.tags = tags
    }
}

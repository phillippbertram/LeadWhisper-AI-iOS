import Foundation

enum DemoAgentParser {
    static func makeDraft(transcript: String, snapshot: CRMDataSnapshot = CRMDataSnapshot(contacts: [], opportunities: [], followUps: [])) -> AgentDraft {
        let key = transcript.searchKey

        if let clarification = maxClarification(for: key, snapshot: snapshot) {
            return AgentDraft(
                summary: "Clarification needed before updating Max.",
                detectedFacts: [
                    DetectedFact(kind: .contact, value: "Max", detail: "Multiple local contacts match this name.")
                ],
                proposedChanges: [],
                clarification: clarification,
                spokenConfirmation: "I found more than one Max. Please choose the right contact."
            )
        }

        if key.contains("verschiebe") || key.contains("reschedule") {
            return followUpRescheduleDraft(transcript: transcript)
        }

        if key.contains("verloren") || key.contains("lost") {
            return lostOpportunityDraft(transcript: transcript)
        }

        if key.contains("max") || key.contains("proposal sent") || key.contains("angebot positiv") {
            return existingContactDraft(transcript: transcript, snapshot: snapshot)
        }

        return newLeadDraft(transcript: transcript)
    }

    private static func newLeadDraft(transcript: String) -> AgentDraft {
        let key = transcript.searchKey
        let contact = detectContact(in: key)
        let tags = detectTags(in: key)
        let stage = detectStage(in: key) ?? .lead
        let budget = detectBudget(in: key)
        let dueDateText = detectDueText(in: key)
        let opportunityTitle = detectOpportunityTitle(in: key)
        let expectedStart = detectExpectedStart(in: key)

        var facts = [
            DetectedFact(kind: .contact, value: contact.name, detail: "Person mentioned in the voice note."),
            DetectedFact(kind: .company, value: contact.company, detail: "Company mentioned near the contact."),
            DetectedFact(kind: .opportunity, value: opportunityTitle, detail: "Client need extracted from the transcript."),
            DetectedFact(kind: .stage, value: stage.title, detail: "Stage requested or inferred for a new lead.")
        ]

        if let budget {
            facts.append(DetectedFact(kind: .budget, value: "EUR \(budget)", detail: "Budget amount detected."))
        }
        if let dueDateText {
            facts.append(DetectedFact(kind: .followUp, value: dueDateText, detail: "Follow-up date requested."))
        }

        var changes = [
            ProposedChange(
                action: .createContact,
                title: "Create Contact",
                contactName: contact.name,
                company: contact.company,
                notes: "Captured from voice note.",
                tags: tags
            ),
            ProposedChange(
                action: .createOpportunity,
                title: "Create Opportunity",
                contactName: contact.name,
                company: contact.company,
                opportunityTitle: opportunityTitle,
                stage: stage.rawValue,
                estimatedValueEUR: budget,
                budgetText: detectBudgetText(in: key),
                expectedStart: expectedStart,
                notes: transcript,
                tags: tags
            )
        ]

        if let dueDateText {
            changes.append(
                ProposedChange(
                    action: .createFollowUp,
                    title: "Create Follow-up",
                    contactName: contact.name,
                    company: contact.company,
                    opportunityTitle: opportunityTitle,
                    followUpTitle: "Send proposal to \(contact.name.components(separatedBy: " ").first ?? contact.name)",
                    dueDateText: dueDateText,
                    notes: "Follow up based on the conversation.",
                    tags: tags
                )
            )
        }

        changes.append(
            ProposedChange(
                action: .createInteraction,
                title: "Add Interaction",
                contactName: contact.name,
                company: contact.company,
                opportunityTitle: opportunityTitle,
                notes: transcript,
                tags: tags
            )
        )

        return AgentDraft(
            summary: "Create or update \(contact.name) at \(contact.company) with a \(opportunityTitle) opportunity.",
            detectedFacts: facts,
            proposedChanges: changes,
            clarification: nil,
            spokenConfirmation: "Done. I saved \(contact.name), the opportunity, and the follow-up locally."
        )
    }

    private static func existingContactDraft(transcript: String, snapshot: CRMDataSnapshot) -> AgentDraft {
        let key = transcript.searchKey
        let max = selectedMaxContact(in: key, snapshot: snapshot) ??
            snapshot.contacts.first { $0.fullName.searchKey.contains("max muller") || $0.fullName.searchKey.contains("max mueller") }
        let opportunity = snapshot.opportunities.first { $0.contactID == max?.id }
        let stage = detectStage(in: key) ?? .proposalSent
        let dueDateText = detectDueText(in: key) ?? "Thursday"
        let contactName = max?.fullName ?? "Max Mueller"
        let company = max?.company ?? "Acme Labs"
        let opportunityTitle = opportunity?.title ?? "Native iOS app"

        return AgentDraft(
            summary: "Update \(contactName) and move the opportunity to \(stage.title).",
            detectedFacts: [
                DetectedFact(kind: .contact, value: contactName, detail: "Existing contact identified."),
                DetectedFact(kind: .stage, value: stage.title, detail: "Opportunity stage requested."),
                DetectedFact(kind: .followUp, value: dueDateText, detail: "Follow-up timing extracted.")
            ],
            proposedChanges: [
                ProposedChange(
                    action: .updateOpportunityStage,
                    title: "Update Opportunity Stage",
                    targetID: nil,
                    contactName: contactName,
                    company: company,
                    opportunityTitle: opportunityTitle,
                    stage: stage.rawValue,
                    notes: transcript,
                    tags: ["Proposal"]
                ),
                ProposedChange(
                    action: .createFollowUp,
                    title: "Create Follow-up",
                    contactName: contactName,
                    company: company,
                    opportunityTitle: opportunityTitle,
                    followUpTitle: "Check in with \(contactName)",
                    dueDateText: dueDateText,
                    notes: "He wants to align internally first.",
                    tags: ["Proposal"]
                ),
                ProposedChange(
                    action: .createInteraction,
                    title: "Add Interaction",
                    contactName: contactName,
                    company: company,
                    opportunityTitle: opportunityTitle,
                    notes: transcript,
                    tags: ["Proposal"]
                )
            ],
            clarification: nil,
            spokenConfirmation: "Done. I updated \(contactName)'s opportunity and created the follow-up."
        )
    }

    private static func followUpRescheduleDraft(transcript: String) -> AgentDraft {
        AgentDraft(
            summary: "Reschedule Sarah's follow-up and add technical concept notes.",
            detectedFacts: [
                DetectedFact(kind: .contact, value: "Sarah Klein", detail: "Contact referenced in the command."),
                DetectedFact(kind: .followUp, value: "next Tuesday", detail: "New due date requested."),
                DetectedFact(kind: .note, value: "Send a short technical concept", detail: "Additional task note.")
            ],
            proposedChanges: [
                ProposedChange(
                    action: .updateFollowUp,
                    title: "Move Follow-up",
                    contactName: "Sarah Klein",
                    company: "BluePeak",
                    followUpTitle: "Send proposal to Sarah",
                    dueDateText: "next Tuesday",
                    notes: "Include a short technical concept.",
                    tags: ["Follow-up"]
                )
            ],
            clarification: nil,
            spokenConfirmation: "Done. I moved Sarah's follow-up to next Tuesday and added the technical concept note."
        )
    }

    private static func lostOpportunityDraft(transcript: String) -> AgentDraft {
        AgentDraft(
            summary: "Mark the BluePeak opportunity as lost and archive related open follow-ups.",
            detectedFacts: [
                DetectedFact(kind: .company, value: "BluePeak", detail: "Company named in the command."),
                DetectedFact(kind: .stage, value: "Lost", detail: "The user asked to mark the opportunity as lost."),
                DetectedFact(kind: .note, value: "Budget too low", detail: "Loss reason.")
            ],
            proposedChanges: [
                ProposedChange(
                    action: .updateOpportunityStage,
                    title: "Mark Opportunity Lost",
                    contactName: "Sarah Klein",
                    company: "BluePeak",
                    opportunityTitle: "Flutter app support",
                    stage: OpportunityStage.lost.rawValue,
                    notes: "Reason: budget too low.",
                    tags: ["Lost"]
                ),
                ProposedChange(
                    action: .archiveFollowUps,
                    title: "Archive Related Follow-ups",
                    contactName: "Sarah Klein",
                    company: "BluePeak",
                    opportunityTitle: "Flutter app support",
                    notes: "Opportunity closed as lost.",
                    tags: ["Lost"]
                )
            ],
            clarification: nil,
            spokenConfirmation: "Done. I marked the BluePeak opportunity as lost and archived the related open follow-ups."
        )
    }
}

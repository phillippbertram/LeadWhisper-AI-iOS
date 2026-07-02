import Foundation
import OSLog

struct AgentDraftValidator {
    static func validate(
        _ result: AgentRunResult,
        userContext: String,
        snapshot: CRMDataSnapshot,
        availabilityMessage: String
    ) -> AgentRunResult {
        guard result.draft.canApply else { return result }

        var draft = result.draft
        var validatedChanges: [ProposedChange] = []

        for change in draft.proposedChanges {
            var validated = change
            if containsPlaceholder(in: validated) {
                AppLog.agent.warning("Blocked placeholder agent draft action=\(change.action.rawValue, privacy: .public)")
                return clarification(
                    "I need the real CRM details before I can draft that.",
                    placeholder: placeholder(for: change.action),
                    timeline: result.timeline,
                    availabilityMessage: availabilityMessage
                )
            }

            switch validated.action {
            case .createContact:
                guard hasRequiredContactFields(validated),
                      valuesCameFromUser(validated, userContext: userContext, fields: [validated.contactName, validated.company]) else {
                    return clarification(
                        "Who is the contact and which company are they with?",
                        placeholder: "Name and company",
                        timeline: result.timeline,
                        availabilityMessage: availabilityMessage
                    )
                }

            case .createOpportunity:
                guard validated.opportunityTitle?.nilIfBlank != nil,
                      validated.contactName?.nilIfBlank != nil || validated.company?.nilIfBlank != nil else {
                    return clarification(
                        "Which opportunity should I create, and who or which company is it for?",
                        placeholder: "Opportunity, contact, and company",
                        timeline: result.timeline,
                        availabilityMessage: availabilityMessage
                    )
                }

            case .createFollowUp:
                guard validated.followUpTitle?.nilIfBlank != nil,
                      validated.contactName?.nilIfBlank != nil ||
                        validated.company?.nilIfBlank != nil ||
                        validated.targetID?.nilIfBlank != nil ||
                        validated.opportunityTitle?.nilIfBlank != nil else {
                    return clarification(
                        "Who is the follow-up for, and what should I remind you to do?",
                        placeholder: "Contact and follow-up task",
                        timeline: result.timeline,
                        availabilityMessage: availabilityMessage
                    )
                }
                validated = resolveCreateFollowUpTarget(validated, snapshot: snapshot)

            case .updateContact:
                guard let contact = resolveContact(for: validated, snapshot: snapshot) else {
                    return clarification(
                        "Which existing contact should I update?",
                        options: contactOptions(snapshot.contacts),
                        placeholder: "Contact name",
                        timeline: result.timeline,
                        availabilityMessage: availabilityMessage
                    )
                }
                validated.targetID = contact.id

            case .updateOpportunity, .updateOpportunityStage:
                guard let opportunity = resolveOpportunity(for: validated, snapshot: snapshot) else {
                    return clarification(
                        "Which existing opportunity should I update?",
                        options: opportunityOptions(snapshot.opportunities),
                        placeholder: "Opportunity name",
                        timeline: result.timeline,
                        availabilityMessage: availabilityMessage
                    )
                }
                validated.targetID = opportunity.id

            case .updateFollowUp, .completeFollowUp:
                guard let followUp = resolveFollowUp(for: validated, snapshot: snapshot) else {
                    return clarification(
                        "Which existing follow-up should I update?",
                        options: followUpOptions(snapshot.followUps),
                        placeholder: "Follow-up title",
                        timeline: result.timeline,
                        availabilityMessage: availabilityMessage
                    )
                }
                validated.targetID = followUp.id

            case .deleteContact:
                guard let contact = resolveContact(for: validated, snapshot: snapshot) else {
                    return clarification(
                        "Which existing contact should I delete?",
                        options: contactOptions(snapshot.contacts),
                        placeholder: "Contact name",
                        timeline: result.timeline,
                        availabilityMessage: availabilityMessage
                    )
                }
                validated.targetID = contact.id

            case .deleteOpportunity:
                guard let opportunity = resolveOpportunity(for: validated, snapshot: snapshot) else {
                    return clarification(
                        "Which existing opportunity should I delete?",
                        options: opportunityOptions(snapshot.opportunities),
                        placeholder: "Opportunity name",
                        timeline: result.timeline,
                        availabilityMessage: availabilityMessage
                    )
                }
                validated.targetID = opportunity.id

            case .deleteFollowUp:
                guard let followUp = resolveFollowUp(for: validated, snapshot: snapshot) else {
                    return clarification(
                        "Which existing follow-up should I delete?",
                        options: followUpOptions(snapshot.followUps),
                        placeholder: "Follow-up title",
                        timeline: result.timeline,
                        availabilityMessage: availabilityMessage
                    )
                }
                validated.targetID = followUp.id

            case .archiveFollowUps, .createInteraction:
                break
            }

            validatedChanges.append(validated)
        }

        draft.proposedChanges = validatedChanges
        return AgentRunResult(
            kind: result.kind,
            message: result.message,
            thought: result.thought,
            draft: draft,
            timeline: result.timeline,
            availabilityMessage: result.availabilityMessage,
            errorMessage: result.errorMessage
        )
    }
}

private extension AgentDraftValidator {
    static let placeholderKeys: [String] = [
        "john doe",
        "jane doe",
        "unknown contact",
        "new opportunity",
        "tbd",
        "to be determined",
        "placeholder",
        "sample contact",
        "example contact"
    ]

    static func containsPlaceholder(in change: ProposedChange) -> Bool {
        stringValues(from: change).contains { value in
            let key = value.searchKey
            return placeholderKeys.contains { key.contains($0) }
        }
    }

    static func stringValues(from change: ProposedChange) -> [String] {
        [
            change.title,
            change.targetID,
            change.contactName,
            change.company,
            change.role,
            change.email,
            change.phone,
            change.opportunityTitle,
            change.stage,
            change.budgetText,
            change.expectedStart,
            change.followUpTitle,
            change.dueDateText,
            change.followUpState,
            change.notes
        ]
        .compactMap { $0?.nilIfBlank }
    }

    static func hasRequiredContactFields(_ change: ProposedChange) -> Bool {
        change.contactName?.nilIfBlank != nil && change.company?.nilIfBlank != nil
    }

    static func valuesCameFromUser(_ change: ProposedChange, userContext: String, fields: [String?]) -> Bool {
        let key = userContext.searchKey
        return fields.compactMap { $0?.nilIfBlank }.allSatisfy { value in
            key.contains(value.searchKey)
        }
    }

    static func resolveCreateFollowUpTarget(_ change: ProposedChange, snapshot: CRMDataSnapshot) -> ProposedChange {
        var resolved = change
        if resolved.targetID?.nilIfBlank != nil {
            return resolved
        }
        if let contact = resolveContact(for: change, snapshot: snapshot) {
            resolved.targetID = contact.id
        } else if let opportunity = resolveOpportunity(for: change, snapshot: snapshot) {
            resolved.targetID = opportunity.contactID
        }
        return resolved
    }

    static func resolveContact(for change: ProposedChange, snapshot: CRMDataSnapshot) -> CRMContactSnapshot? {
        if let targetID = change.targetID?.nilIfBlank,
           let contact = snapshot.contacts.first(where: { $0.id == targetID }) {
            return contact
        }

        let nameKey = change.contactName?.searchKey ?? ""
        let companyKey = change.company?.searchKey ?? ""
        let matches = snapshot.contacts.filter { contact in
            let nameMatches = nameKey.isEmpty ||
                contact.fullName.searchKey == nameKey ||
                contact.fullName.searchKey.contains(nameKey) ||
                nameKey.contains(contact.fullName.searchKey)
            let companyMatches = companyKey.isEmpty ||
                contact.company.searchKey == companyKey ||
                contact.company.searchKey.contains(companyKey)
            return nameMatches && companyMatches
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    static func resolveOpportunity(for change: ProposedChange, snapshot: CRMDataSnapshot) -> CRMOpportunitySnapshot? {
        if let targetID = change.targetID?.nilIfBlank,
           let opportunity = snapshot.opportunities.first(where: { $0.id == targetID }) {
            return opportunity
        }

        let titleKey = change.opportunityTitle?.searchKey ?? ""
        let companyKey = change.company?.searchKey ?? ""
        let matches = snapshot.opportunities.filter { opportunity in
            let titleMatches = titleKey.isEmpty ||
                opportunity.title.searchKey == titleKey ||
                opportunity.title.searchKey.contains(titleKey) ||
                titleKey.contains(opportunity.title.searchKey)
            let companyMatches = companyKey.isEmpty ||
                opportunity.company.searchKey == companyKey ||
                opportunity.company.searchKey.contains(companyKey)
            return titleMatches && companyMatches
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    static func resolveFollowUp(for change: ProposedChange, snapshot: CRMDataSnapshot) -> CRMFollowUpSnapshot? {
        if let targetID = change.targetID?.nilIfBlank,
           let followUp = snapshot.followUps.first(where: { $0.id == targetID }) {
            return followUp
        }

        let titleKey = change.followUpTitle?.searchKey ?? ""
        let matches = snapshot.followUps.filter { followUp in
            titleKey.isEmpty ||
                followUp.title.searchKey == titleKey ||
                followUp.title.searchKey.contains(titleKey) ||
                titleKey.contains(followUp.title.searchKey)
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    static func contactOptions(_ contacts: [CRMContactSnapshot]) -> [String] {
        contacts.prefix(4).map {
            if let company = $0.company.nilIfBlank {
                return "\($0.fullName) at \(company)"
            }
            return $0.fullName
        }
    }

    static func opportunityOptions(_ opportunities: [CRMOpportunitySnapshot]) -> [String] {
        opportunities.prefix(4).map {
            if let company = $0.company.nilIfBlank {
                return "\($0.title) at \(company)"
            }
            return $0.title
        }
    }

    static func followUpOptions(_ followUps: [CRMFollowUpSnapshot]) -> [String] {
        followUps.prefix(4).map(\.title)
    }

    static func placeholder(for action: ProposedChangeAction) -> String {
        switch action {
        case .createContact:
            "Name and company"
        case .createOpportunity, .updateOpportunity, .updateOpportunityStage, .deleteOpportunity:
            "Opportunity name"
        case .createFollowUp, .updateFollowUp, .completeFollowUp, .deleteFollowUp, .archiveFollowUps:
            "Follow-up details"
        case .updateContact, .deleteContact, .createInteraction:
            "Contact details"
        }
    }

    static func clarification(
        _ question: String,
        options: [String] = [],
        placeholder: String?,
        timeline: [AgentTimelineItem],
        availabilityMessage: String
    ) -> AgentRunResult {
        AgentRunResult(
            kind: .clarify,
            message: question,
            thought: "",
            draft: AgentDraft(
                summary: "",
                detectedFacts: [],
                proposedChanges: [],
                clarification: ClarificationPrompt(
                    question: question,
                    options: options,
                    allowsFreeText: true,
                    placeholder: placeholder
                ),
                spokenConfirmation: ""
            ),
            timeline: timeline + [
                AgentTimelineItem(title: "Draft validation", detail: "Blocked an unsafe or incomplete model draft.", systemImage: "shield.lefthalf.filled")
            ],
            availabilityMessage: availabilityMessage,
            errorMessage: nil
        )
    }
}

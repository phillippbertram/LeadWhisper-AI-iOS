import SwiftUI

struct AgentSuggestion: Hashable, Identifiable {
    var title: String
    var subtitle: String?
    var systemImage: String
    var prompt: String

    var id: String {
        "\(title)|\(prompt)".searchKey
    }
}

/// Hero shown while the conversation is empty, with tappable suggestions built
/// from the user's actual CRM data.
struct AgentEmptyStateView: View {
    let suggestions: [AgentSuggestion]
    let select: (String) -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(
                    LinearGradient(colors: [.cyan, .blue, .green], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Circle()
                )
                .shadow(color: .blue.opacity(0.18), radius: 10, x: 0, y: 5)

            VStack(spacing: 6) {
                Text("Chat with your CRM")
                    .font(.title3.bold())
                Text("Describe what happened with a lead. I'll ask for anything missing and draft the changes - nothing is saved without your review.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                ForEach(suggestions) { suggestion in
                    SuggestionRow(suggestion: suggestion, select: select)
                }
            }
        }
        .padding(.top, 28)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
    }
}

private struct SuggestionRow: View {
    let suggestion: AgentSuggestion
    let select: (String) -> Void

    var body: some View {
        Button {
            select(suggestion.prompt)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: suggestion.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    if let subtitle = suggestion.subtitle?.nilIfBlank {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.message")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.blue.opacity(0.14))
            }
        }
        .buttonStyle(.plain)
    }
}

enum AgentSuggestionBuilder {
    private static let meetingNotePrompt = """
    Meeting note from today:

    I spoke with Elena Fischer, Head of Operations at GreenGrid Energy. Her email is elena.fischer@greengrid.energy and her phone number is +49 30 5550 1842.

    GreenGrid Energy wants a native iOS companion app for field technicians. The app should work offline, sync visit notes later, send push reminders, and hand completed jobs over to their dashboard. Elena said the project is qualified, the budget is about EUR 48,000, and they would like to start in October.

    She asked for a proposal next week and wants the first version to focus on offline sync and the technician workflow.

    Please create everything useful from this meeting note: the contact, the opportunity, a meeting interaction, and a follow-up to send the proposal next Tuesday.
    """

    /// Builds starter suggestions from the local CRM so the empty state shows
    /// real records instead of canned demo text whenever data exists.
    static func suggestions(from snapshot: CRMDataSnapshot) -> [AgentSuggestion] {
        var items = [
            AgentSuggestion(
                title: "I have a new lead",
                subtitle: "I'll ask for the person, company, and next step",
                systemImage: "person.crop.circle.badge.plus",
                prompt: "I have a new lead"
            ),
            AgentSuggestion(
                title: "Turn a meeting note into CRM",
                subtitle: "Creates a contact, opportunity, note, and follow-up draft",
                systemImage: "doc.text",
                prompt: meetingNotePrompt
            )
        ]

        let hasData = !snapshot.contacts.isEmpty || !snapshot.opportunities.isEmpty || !snapshot.followUps.isEmpty
        guard hasData else {
            items.append(contentsOf: [
                AgentSuggestion(
                    title: "Create a follow-up",
                    subtitle: "I'll first ask which lead it belongs to",
                    systemImage: "bell.badge",
                    prompt: "Create a follow-up"
                ),
                AgentSuggestion(
                    title: "Update a contact",
                    subtitle: "Works once local contacts exist",
                    systemImage: "square.and.pencil",
                    prompt: "Update a contact"
                ),
                AgentSuggestion(
                    title: "What is due today?",
                    subtitle: "I'll answer from local CRM data only",
                    systemImage: "calendar.badge.clock",
                    prompt: "What is due today?"
                )
            ])
            return Array(items.prefix(5))
        }

        items.append(AgentSuggestion(
            title: "What's due right now?",
            subtitle: "Open follow-ups and pipeline overview",
            systemImage: "calendar.badge.clock",
            prompt: "What is due in my pipeline right now?"
        ))

        if let contact = snapshot.contacts.first {
            items.append(AgentSuggestion(
                title: "Update \(contact.fullName)",
                subtitle: "I'll ask what changed",
                systemImage: "square.and.pencil",
                prompt: "Update \(contact.fullName)"
            ))
        }

        let openOpportunity = snapshot.opportunities.first {
            $0.stage != OpportunityStage.won.rawValue && $0.stage != OpportunityStage.lost.rawValue
        } ?? snapshot.opportunities.first
        if let opportunity = openOpportunity {
            items.append(AgentSuggestion(
                title: "Move \(opportunity.title)",
                subtitle: "Pick the next pipeline stage",
                systemImage: "chart.line.uptrend.xyaxis",
                prompt: "Update the stage of the opportunity \(opportunity.title) at \(opportunity.company)"
            ))
        }

        if let followUp = snapshot.followUps.first(where: { $0.state == FollowUpState.open.rawValue }) {
            items.append(AgentSuggestion(
                title: "Complete \(followUp.title)",
                subtitle: followUp.dueDateText.nilIfBlank ?? "Mark this follow-up as done",
                systemImage: "checkmark.circle",
                prompt: "Mark the follow-up \(followUp.title) as done"
            ))
        }

        return Array(items.prefix(5))
    }

    static func contextualSuggestions(
        from snapshot: CRMDataSnapshot,
        prefersFollowUpActions: Bool = false
    ) -> [AgentSuggestion] {
        var items: [AgentSuggestion] = []

        if prefersFollowUpActions,
           let followUp = openFollowUp(from: snapshot) {
            appendUnique(
                AgentSuggestion(
                    title: "Complete \(followUp.title)",
                    subtitle: followUp.dueDateText.nilIfBlank ?? "Mark this follow-up as done",
                    systemImage: "checkmark.circle",
                    prompt: "Mark the follow-up \(followUp.title) as done"
                ),
                to: &items
            )
        }

        if let opportunity = activeOpportunity(from: snapshot) {
            appendUnique(
                AgentSuggestion(
                    title: "Create follow-up",
                    subtitle: opportunity.title,
                    systemImage: "bell.badge",
                    prompt: "Create a follow-up for the opportunity \(opportunity.title)"
                ),
                to: &items
            )

            if shouldSuggestProposalSent(for: opportunity) {
                appendUnique(
                    AgentSuggestion(
                        title: "Mark proposal sent",
                        subtitle: opportunity.title,
                        systemImage: "paperplane",
                        prompt: "Move the opportunity \(opportunity.title) to proposal sent"
                    ),
                    to: &items
                )
            }
        } else if let contact = snapshot.contacts.first {
            appendUnique(
                AgentSuggestion(
                    title: "Create follow-up",
                    subtitle: contact.fullName,
                    systemImage: "bell.badge",
                    prompt: "Create a follow-up for \(contact.fullName)"
                ),
                to: &items
            )
        } else {
            appendUnique(
                AgentSuggestion(
                    title: "Create follow-up",
                    subtitle: "I'll ask who it belongs to",
                    systemImage: "bell.badge",
                    prompt: "Create a follow-up"
                ),
                to: &items
            )
        }

        if let followUp = openFollowUp(from: snapshot) {
            appendUnique(
                AgentSuggestion(
                    title: "Complete \(followUp.title)",
                    subtitle: followUp.dueDateText.nilIfBlank ?? "Mark this follow-up as done",
                    systemImage: "checkmark.circle",
                    prompt: "Mark the follow-up \(followUp.title) as done"
                ),
                to: &items
            )
        }

        if let contact = snapshot.contacts.first {
            appendUnique(
                AgentSuggestion(
                    title: "Update \(contact.fullName)",
                    subtitle: contact.company.nilIfBlank ?? "Add a CRM update",
                    systemImage: "square.and.pencil",
                    prompt: "Update \(contact.fullName)"
                ),
                to: &items
            )
        } else {
            appendUnique(
                AgentSuggestion(
                    title: "Update a contact",
                    subtitle: "I'll ask which one",
                    systemImage: "square.and.pencil",
                    prompt: "Update a contact"
                ),
                to: &items
            )
        }

        appendUnique(
            AgentSuggestion(
                title: "What's due next?",
                subtitle: "Open follow-ups and pipeline overview",
                systemImage: "calendar.badge.clock",
                prompt: "What is due next in my pipeline?"
            ),
            to: &items
        )

        return Array(items.prefix(4))
    }

    static func receiptSuggestions(from changedRecords: [ChangedCRMRecord]) -> [AgentSuggestion] {
        var items: [AgentSuggestion] = []

        if let record = changedRecords.first(where: { $0.kind == .contact && $0.canOpen }) {
            appendUnique(
                AgentSuggestion(
                    title: "Add follow-up",
                    subtitle: record.title,
                    systemImage: "bell.badge",
                    prompt: "Create a follow-up for \(record.title)"
                ),
                to: &items
            )
        } else if let record = changedRecords.first(where: { $0.kind == .opportunity && $0.canOpen }) {
            appendUnique(
                AgentSuggestion(
                    title: "Add follow-up",
                    subtitle: record.title,
                    systemImage: "bell.badge",
                    prompt: "Create a follow-up for the opportunity \(record.title)"
                ),
                to: &items
            )
        }

        if let record = changedRecords.first(where: { $0.kind == .opportunity && $0.canOpen }) {
            appendUnique(
                AgentSuggestion(
                    title: "Mark proposal sent",
                    subtitle: record.title,
                    systemImage: "paperplane",
                    prompt: "Move the opportunity \(record.title) to proposal sent"
                ),
                to: &items
            )
        }

        appendUnique(
            AgentSuggestion(
                title: "What's due next?",
                subtitle: "Open follow-ups and pipeline overview",
                systemImage: "calendar.badge.clock",
                prompt: "What is due next in my pipeline?"
            ),
            to: &items
        )

        return Array(items.prefix(3))
    }

    private static func openFollowUp(from snapshot: CRMDataSnapshot) -> CRMFollowUpSnapshot? {
        snapshot.followUps.first { $0.state == FollowUpState.open.rawValue }
    }

    private static func activeOpportunity(from snapshot: CRMDataSnapshot) -> CRMOpportunitySnapshot? {
        snapshot.opportunities.first {
            $0.stage != OpportunityStage.won.rawValue && $0.stage != OpportunityStage.lost.rawValue
        } ?? snapshot.opportunities.first
    }

    private static func shouldSuggestProposalSent(for opportunity: CRMOpportunitySnapshot) -> Bool {
        opportunity.stage != OpportunityStage.proposalSent.rawValue &&
            opportunity.stage != OpportunityStage.won.rawValue &&
            opportunity.stage != OpportunityStage.lost.rawValue
    }

    private static func appendUnique(_ suggestion: AgentSuggestion, to items: inout [AgentSuggestion]) {
        guard !items.contains(where: { $0.id == suggestion.id }) else { return }
        items.append(suggestion)
    }
}

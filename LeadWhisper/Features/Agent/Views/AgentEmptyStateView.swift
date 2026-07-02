import SwiftUI

struct AgentSuggestion: Identifiable {
    let id = UUID()
    var title: String
    var subtitle: String?
    var systemImage: String
    var prompt: String
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
    /// Builds starter suggestions from the local CRM so the empty state shows
    /// real records instead of canned demo text whenever data exists.
    static func suggestions(from snapshot: CRMDataSnapshot) -> [AgentSuggestion] {
        var items = [
            AgentSuggestion(
                title: "I have a new lead",
                subtitle: "I'll ask for the person, company, and next step",
                systemImage: "person.crop.circle.badge.plus",
                prompt: "I have a new lead"
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
            return Array(items.prefix(4))
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

        return Array(items.prefix(4))
    }
}

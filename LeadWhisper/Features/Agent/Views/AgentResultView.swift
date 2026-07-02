import SwiftUI

struct AgentResultView: View {
    let runResult: AgentRunResult
    var showsActions = true
    let save: () -> Void
    let cancel: () -> Void
    let answerClarification: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let errorMessage = runResult.errorMessage?.nilIfBlank {
                AgentNoticeView(
                    title: runResult.draft.summary.nilIfBlank ?? "Could not draft changes",
                    detail: errorMessage,
                    systemImage: "exclamationmark.triangle",
                    tint: .orange
                )
            }

            if !runResult.timeline.isEmpty {
                AgentTimelineView(items: runResult.timeline)
            }

            if !runResult.draft.detectedFacts.isEmpty {
                DetectedFactsView(facts: runResult.draft.detectedFacts)
            }

            if let clarification = runResult.draft.clarification {
                ClarificationView(clarification: clarification, isEnabled: showsActions, select: answerClarification)
                if showsActions {
                    cancelDraftButton
                }
            } else if !runResult.draft.proposedChanges.isEmpty {
                ProposedChangesView(changes: runResult.draft.proposedChanges)
                if showsActions && runResult.draft.canApply {
                    reviewActionButtons
                }
            } else if runResult.errorMessage == nil {
                AgentNoticeView(
                    title: "I need a little more context",
                    detail: "Tell me which contact, opportunity, or follow-up you want to change and what should happen next.",
                    systemImage: "questionmark.circle",
                    tint: .blue
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reviewActionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                cancelButton
                saveButton
            }

            VStack(spacing: 10) {
                saveButton
                cancelButton
            }
        }
    }

    private var cancelButton: some View {
        Button(role: .cancel, action: cancel) {
            Label("Cancel", systemImage: "xmark")
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
    }

    private var cancelDraftButton: some View {
        Button(role: .cancel, action: cancel) {
            Label("Cancel Draft", systemImage: "xmark")
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
    }

    private var saveButton: some View {
        Button(action: save) {
            Label("Save Changes", systemImage: "checkmark")
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!runResult.draft.canApply)
    }
}

private struct AgentTimelineView: View {
    let items: [AgentTimelineItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What I checked")
                .font(.subheadline.weight(.semibold))
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.systemImage)
                        .foregroundStyle(.blue)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.footnote.weight(.semibold))
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct DetectedFactsView: View {
    let facts: [DetectedFact]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Detected Facts")
                .font(.headline)
            ForEach(facts, id: \.self) { fact in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: fact.kind.systemImage)
                        .foregroundStyle(.green)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fact.value)
                            .font(.subheadline.weight(.semibold))
                        Text(fact.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProposedChangesView: View {
    let changes: [ProposedChange]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Proposed Changes")
                .font(.headline)
            ForEach(changes) { change in
                ProposedChangeCard(change: change)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AgentNoticeView: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.18))
        }
    }
}

private struct ProposedChangeCard: View {
    let change: ProposedChange

    private var isDestructive: Bool {
        change.action.isDestructive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(change.title, systemImage: change.action.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isDestructive ? .red : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(change.action.rawValue)
                    .font(.caption2)
                    .foregroundStyle(isDestructive ? .red : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            ProposedChangeDetails(change: change)
                .font(.footnote)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isDestructive ? Color.red.opacity(0.08) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isDestructive ? Color.red.opacity(0.28) : Color.secondary.opacity(0.18))
        }
    }
}

private struct ProposedChangeDetails: View {
    let change: ProposedChange

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let contactName = change.contactName?.nilIfBlank {
                ChangeDetailRow(title: "Contact", value: contactName)
            }
            if let company = change.company?.nilIfBlank {
                ChangeDetailRow(title: "Company", value: company)
            }
            if let role = change.role?.nilIfBlank {
                ChangeDetailRow(title: "Role", value: role)
            }
            if let email = change.email?.nilIfBlank {
                ChangeDetailRow(title: "Email", value: email)
            }
            if let phone = change.phone?.nilIfBlank {
                ChangeDetailRow(title: "Phone", value: phone)
            }
            if let opportunityTitle = change.opportunityTitle?.nilIfBlank {
                ChangeDetailRow(title: "Opportunity", value: opportunityTitle)
            }
            if let stage = change.stage.flatMap(OpportunityStage.from) {
                ChangeDetailRow(title: "Stage", value: stage.title)
            }
            if let value = change.estimatedValueEUR {
                ChangeDetailRow(title: "Value", value: value.formatted(.currency(code: "EUR").precision(.fractionLength(0))))
            } else if let budget = change.budgetText?.nilIfBlank {
                ChangeDetailRow(title: "Budget", value: budget)
            }
            if let dueDate = change.dueDateText?.nilIfBlank {
                ChangeDetailRow(title: "Due", value: dueDate)
            }
            if let state = change.followUpState?.nilIfBlank {
                ChangeDetailRow(title: "State", value: FollowUpState(rawValue: state)?.title ?? state)
            }
            if let notes = change.notes?.nilIfBlank {
                Text(notes)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            TagStrip(tags: change.tags)
        }
    }
}

private struct ChangeDetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension DetectedFactKind {
    var systemImage: String {
        switch self {
        case .contact:
            "person"
        case .company:
            "building.2"
        case .opportunity:
            "chart.line.uptrend.xyaxis"
        case .budget:
            "eurosign.circle"
        case .stage:
            "flag"
        case .followUp:
            "bell"
        case .tag:
            "tag"
        case .note:
            "note.text"
        case .startDate:
            "calendar"
        }
    }
}

private extension ProposedChangeAction {
    var systemImage: String {
        switch self {
        case .createContact, .updateContact:
            "person.crop.circle.badge.plus"
        case .createOpportunity, .updateOpportunity, .updateOpportunityStage:
            "chart.line.uptrend.xyaxis"
        case .createFollowUp, .updateFollowUp, .completeFollowUp, .archiveFollowUps:
            "bell"
        case .deleteContact, .deleteOpportunity, .deleteFollowUp:
            "trash"
        case .createInteraction:
            "text.bubble"
        }
    }
}

private struct ClarificationView: View {
    let clarification: ClarificationPrompt
    let isEnabled: Bool
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "questionmark.bubble")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text("I need one detail before I can draft this.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(clarification.question)
                        .font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(clarification.options, id: \.self) { option in
                Button {
                    select(option)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: iconName(for: option))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.blue)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(nil)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Use this answer")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.message")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.blue.opacity(0.16))
                    }
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func iconName(for option: String) -> String {
        let key = option.searchKey
        if key.contains("yes") || key.contains("no") || key.contains("unclear") {
            return "checkmark.circle"
        }
        if key.contains("follow") || key.contains("task") {
            return "bell"
        }
        if key.contains("opportunity") || key.contains("proposal") {
            return "chart.line.uptrend.xyaxis"
        }
        return "person.crop.circle"
    }
}

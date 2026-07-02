import SwiftUI

struct AgentResultView: View {
    let runResult: AgentRunResult
    let save: () -> Void
    let cancel: () -> Void
    let answerClarification: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if runResult.usedMockParser {
                Label("Demo parser fallback", systemImage: "switch.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AgentTimelineView(items: runResult.timeline)
            DetectedFactsView(facts: runResult.draft.detectedFacts)

            if let clarification = runResult.draft.clarification {
                ClarificationView(clarification: clarification, select: answerClarification)
                cancelDraftButton
            } else {
                ProposedChangesView(changes: runResult.draft.proposedChanges)
                reviewActionButtons
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Agent Plan")
                .font(.headline)
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.systemImage)
                        .foregroundStyle(.blue)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                        Text(item.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DetectedFactsView: View {
    let facts: [DetectedFact]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Detected Facts")
                .font(.headline)
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(for: fact.kind))
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

    private func icon(for kind: String) -> String {
        switch kind {
        case "contact":
            "person"
        case "company":
            "building.2"
        case "opportunity":
            "chart.line.uptrend.xyaxis"
        case "budget":
            "eurosign.circle"
        case "stage":
            "flag"
        case "followUp":
            "bell"
        default:
            "note.text"
        }
    }
}

private struct ProposedChangesView: View {
    let changes: [ProposedChange]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Proposed Changes")
                .font(.headline)
            ForEach(changes) { change in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Label(change.title, systemImage: icon(for: change.action))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(change.action)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        if let contactName = change.contactName?.nilIfBlank {
                            ChangeDetailRow(title: "Contact", value: contactName)
                        }
                        if let company = change.company?.nilIfBlank {
                            ChangeDetailRow(title: "Company", value: company)
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
                        if let notes = change.notes?.nilIfBlank {
                            Text(notes)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        TagStrip(tags: change.tags)
                    }
                    .font(.footnote)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func icon(for action: String) -> String {
        switch action {
        case "createContact", "updateContact":
            "person.crop.circle.badge.plus"
        case "createOpportunity", "updateOpportunityStage":
            "chart.line.uptrend.xyaxis"
        case "createFollowUp", "updateFollowUp", "archiveFollowUps":
            "bell"
        default:
            "text.bubble"
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

private struct ClarificationView: View {
    let clarification: ClarificationPrompt
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Clarification Needed", systemImage: "questionmark.circle")
                .font(.headline)
            Text(clarification.question)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(clarification.options, id: \.self) { option in
                Button {
                    select(option)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.title3)
                            .frame(width: 24)
                        Text(option)
                            .font(.headline)
                            .lineLimit(nil)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.blue.opacity(0.22))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

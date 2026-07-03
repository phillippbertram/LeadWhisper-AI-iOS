import SwiftUI

struct AgentMessageRow: View {
    let message: AgentConversationMessage
    let activeResultID: UUID?
    let openChangedRecord: ((ChangedCRMRecord) -> Void)?
    let save: (AgentRunResult, String, [ProposedChange], Set<String>) -> Void
    let cancel: (AgentRunResult) -> Void

    var body: some View {
        switch message.content {
        case .assistant(let title, let detail, let systemImage):
            AssistantBubble(title: title, detail: detail, systemImage: systemImage)

        case .followUpOverview(let title, let items):
            FollowUpOverviewBubble(title: title, items: items, open: openChangedRecord)

        case .user(let text):
            UserBubble(text: text)

        case .result(let runResult, let transcript):
            AgentResultBubble(
                runResult: runResult,
                transcript: transcript,
                isActive: runResult.id == activeResultID,
                save: save,
                cancel: cancel
            )

        case .receipt(let changedRecords):
            ReceiptBubble(changedRecords: changedRecords, open: openChangedRecord)
        }
    }
}

private struct AssistantBubble: View {
    let title: String
    let detail: String?
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(systemImage: systemImage)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 36)
        }
    }
}

private struct FollowUpOverviewBubble: View {
    let title: String
    let items: [AgentFollowUpOverviewItem]
    let open: ((ChangedCRMRecord) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(systemImage: "calendar.badge.clock")
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        FollowUpOverviewRow(item: item, open: open)
                    }
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 36)
        }
    }
}

private struct FollowUpOverviewRow: View {
    let item: AgentFollowUpOverviewItem
    let open: ((ChangedCRMRecord) -> Void)?

    var body: some View {
        if let open {
            Button {
                open(item.changedRecord)
            } label: {
                rowContent(showsChevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Follow-up, \(item.title), due \(item.dueDateText)")
        } else {
            rowContent(showsChevron: false)
        }
    }

    private var relatedText: String? {
        let values = [item.contactTitle, item.opportunityTitle]
            .compactMap { $0?.nilIfBlank }
        return values.isEmpty ? nil : values.joined(separator: " / ")
    }

    private func rowContent(showsChevron: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.badge")
                .font(.headline)
                .foregroundStyle(.orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Label(item.dueDateText, systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if let relatedText {
                    Label(relatedText, systemImage: "person.text.rectangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.14))
        }
    }
}

private struct UserBubble: View {
    let text: String
    @State private var isExpanded = false

    private var shouldCollapse: Bool {
        text.count > 260 || text.filter { $0 == "\n" }.count >= 5
    }

    var body: some View {
        HStack {
            Spacer(minLength: 46)
            VStack(alignment: .trailing, spacing: 7) {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(shouldCollapse && !isExpanded ? 6 : nil)
                    .fixedSize(horizontal: false, vertical: true)

                if shouldCollapse {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Label(isExpanded ? "Hide" : "Show full note", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.86))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                LinearGradient(
                    colors: [.blue, .cyan],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .shadow(color: .blue.opacity(0.12), radius: 10, x: 0, y: 5)
        }
    }
}

private struct AgentResultBubble: View {
    let runResult: AgentRunResult
    let transcript: String
    let isActive: Bool
    let save: (AgentRunResult, String, [ProposedChange], Set<String>) -> Void
    let cancel: (AgentRunResult) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(systemImage: avatarImage)
            AgentResultView(
                runResult: runResult,
                showsActions: isActive,
                save: { proposedChanges, selectedChangeIDs in save(runResult, transcript, proposedChanges, selectedChangeIDs) },
                cancel: { cancel(runResult) }
            )
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var avatarImage: String {
        if runResult.draft.containsDestructiveChange {
            return "exclamationmark.triangle.fill"
        }
        return runResult.kind == .clarify ? "questionmark.bubble" : "sparkles"
    }
}

private struct ReceiptBubble: View {
    let changedRecords: [ChangedCRMRecord]
    let open: ((ChangedCRMRecord) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(systemImage: "checkmark.seal.fill")
            VStack(alignment: .leading, spacing: 8) {
                Text("Saved to your CRM")
                    .font(.subheadline.weight(.semibold))
                if !changedRecords.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(changedRecords) { record in
                            ReceiptRecordRow(record: record, open: open)
                        }
                    }
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 36)
        }
    }
}

private struct ReceiptRecordRow: View {
    let record: ChangedCRMRecord
    let open: ((ChangedCRMRecord) -> Void)?

    var body: some View {
        if let open, record.canOpen, record.kind.isOpenableFromAgentReceipt {
            Button {
                open(record)
            } label: {
                rowContent(actionTitle: record.kind.openActionTitle, showsChevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(record.kind.openActionTitle), \(record.title)")
        } else {
            rowContent(actionTitle: record.canOpen ? record.kind.receiptTitle : "Deleted from CRM", showsChevron: false)
        }
    }

    private func rowContent(actionTitle: String, showsChevron: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: record.kind.systemImage)
                .font(.caption)
                .foregroundStyle(.green)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(actionTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
            }
        }
        .padding(.vertical, 3)
    }
}

private extension ActivityEntityKind {
    var isOpenableFromAgentReceipt: Bool {
        switch self {
        case .contact, .opportunity, .followUp:
            true
        case .interaction, .system:
            false
        }
    }

    var openActionTitle: String {
        switch self {
        case .contact:
            "Open Contact"
        case .opportunity:
            "Open Opportunity"
        case .followUp:
            "Open Follow-up"
        case .interaction:
            "Activity saved"
        case .system:
            "Saved"
        }
    }

    var receiptTitle: String {
        switch self {
        case .contact:
            "Contact saved"
        case .opportunity:
            "Opportunity saved"
        case .followUp:
            "Follow-up saved"
        case .interaction:
            "Activity saved"
        case .system:
            "Saved"
        }
    }
}

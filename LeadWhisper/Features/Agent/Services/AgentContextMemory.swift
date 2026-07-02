import Foundation

/// Compact continuity state that survives session resets without carrying the
/// full Foundation Models transcript and completed tool calls forward.
struct AgentContextMemory: Sendable {
    enum DraftOutcome: String, Sendable {
        case saved
        case cancelled
    }

    private enum Limits {
        static let recentTurns = 4
        static let outcomes = 4
        static let relevantRecords = 8
        static let compactTextCharacters = 180
        static let refreshEveryTurns = 3
    }

    private var recentTurns: [MemoryTurn] = []
    private var outcomes: [String] = []
    private var relevantRecords: [MemoryRecord] = []
    private var pendingDraftSummary: String?
    private(set) var openClarification: String?
    private(set) var turnsSinceSessionRefresh = 0

    var shouldRefreshSession: Bool {
        turnsSinceSessionRefresh >= Limits.refreshEveryTurns
    }

    var estimatedTokenCount: Int {
        roughTokenCount(promptPrefix() ?? "")
    }

    var isEmpty: Bool {
        recentTurns.isEmpty &&
            outcomes.isEmpty &&
            relevantRecords.isEmpty &&
            pendingDraftSummary == nil &&
            openClarification == nil
    }

    mutating func reset() {
        recentTurns = []
        outcomes = []
        relevantRecords = []
        pendingDraftSummary = nil
        openClarification = nil
        turnsSinceSessionRefresh = 0
    }

    mutating func recordUserMessage(_ message: String) {
        appendTurn(role: "User", text: message)
        turnsSinceSessionRefresh += 1
    }

    mutating func record(_ result: AgentRunResult) {
        appendTurn(role: "Assistant", text: result.message)

        if result.kind == .clarify {
            openClarification = result.draft.clarification?.question.nilIfBlank
        } else {
            openClarification = nil
        }

        if result.kind == .propose, !result.draft.proposedChanges.isEmpty {
            pendingDraftSummary = draftSummary(for: result.draft)
            recordRelevantTargets(from: result.draft.proposedChanges)
        }
    }

    mutating func recordOutcome(_ outcome: DraftOutcome) {
        let summary = pendingDraftSummary ?? "last draft"
        appendOutcome("\(outcome.rawValue) \(summary)")
        pendingDraftSummary = nil
        openClarification = nil
        turnsSinceSessionRefresh = Limits.refreshEveryTurns
    }

    mutating func markSessionRefreshed() {
        turnsSinceSessionRefresh = 0
    }

    func promptPrefix() -> String? {
        guard !isEmpty else { return nil }

        var lines = [
            "Context memory from earlier turns. Treat it as continuity, but verify local IDs with tools before updating or deleting records."
        ]

        if !recentTurns.isEmpty {
            lines.append("Recent turns:")
            lines += recentTurns.map { "- \($0.role): \($0.text)" }
        }

        if let openClarification {
            lines.append("Open question: \(openClarification)")
        }

        if !relevantRecords.isEmpty {
            lines.append("Relevant local records:")
            lines += relevantRecords.map { "- \($0.kind) id=\($0.id) \($0.label)" }
        }

        if let pendingDraftSummary {
            lines.append("Pending draft: \(pendingDraftSummary)")
        }

        if !outcomes.isEmpty {
            lines.append("Recent draft outcomes:")
            lines += outcomes.map { "- \($0)" }
        }

        return lines.joined(separator: "\n")
    }

    private mutating func appendTurn(role: String, text: String) {
        guard let compact = compactText(text) else { return }
        recentTurns.append(MemoryTurn(role: role, text: compact))
        if recentTurns.count > Limits.recentTurns {
            recentTurns.removeFirst(recentTurns.count - Limits.recentTurns)
        }
    }

    private mutating func appendOutcome(_ outcome: String) {
        outcomes.append(compactText(outcome) ?? outcome)
        if outcomes.count > Limits.outcomes {
            outcomes.removeFirst(outcomes.count - Limits.outcomes)
        }
    }

    private mutating func recordRelevantTargets(from changes: [ProposedChange]) {
        for change in changes {
            guard let id = change.targetID?.nilIfBlank else { continue }
            let record = MemoryRecord(
                id: id,
                kind: change.action.recordKind,
                label: compactText(change.memoryLabel) ?? change.action.rawValue
            )

            if let index = relevantRecords.firstIndex(where: { $0.id == id }) {
                relevantRecords[index] = record
            } else {
                relevantRecords.append(record)
            }
        }

        if relevantRecords.count > Limits.relevantRecords {
            relevantRecords.removeFirst(relevantRecords.count - Limits.relevantRecords)
        }
    }

    private func draftSummary(for draft: AgentDraft) -> String {
        let actions = draft.proposedChanges
            .prefix(4)
            .map { "\($0.action.rawValue): \($0.memoryLabel)" }
            .joined(separator: "; ")
        return "draft with \(draft.proposedChanges.count) change(s)" + (actions.isEmpty ? "" : " - \(actions)")
    }

    private func compactText(_ text: String) -> String? {
        guard let trimmed = text.nilIfBlank else { return nil }
        guard trimmed.count > Limits.compactTextCharacters else { return trimmed }
        return "\(trimmed.prefix(Limits.compactTextCharacters - 3))..."
    }
}

private struct MemoryTurn: Sendable {
    var role: String
    var text: String
}

private struct MemoryRecord: Sendable {
    var id: String
    var kind: String
    var label: String
}

private extension ProposedChange {
    var memoryLabel: String {
        [
            title.nilIfBlank,
            contactName?.nilIfBlank,
            company?.nilIfBlank,
            opportunityTitle?.nilIfBlank,
            followUpTitle?.nilIfBlank
        ]
        .compactMap(\.self)
        .prefix(3)
        .joined(separator: " / ")
    }
}

private extension ProposedChangeAction {
    var recordKind: String {
        switch self {
        case .createContact, .updateContact, .deleteContact:
            "contact"
        case .createOpportunity, .updateOpportunity, .updateOpportunityStage, .deleteOpportunity:
            "opportunity"
        case .createFollowUp, .updateFollowUp, .completeFollowUp, .archiveFollowUps, .deleteFollowUp:
            "followUp"
        case .createInteraction:
            "interaction"
        }
    }
}

private func roughTokenCount(_ text: String) -> Int {
    guard !text.isEmpty else { return 0 }
    return max(1, Int((Double(text.count) / 4.0).rounded(.up)))
}

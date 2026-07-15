import Foundation
import SwiftAgentKit

struct AgentContextMemoryLimits: Sendable, Hashable {
    var recentTurns: Int
    var outcomes: Int
    var relevantRecords: Int
    var compactTextCharacters: Int
    var refreshEveryTurns: Int?

    static let appleFoundationModels = AgentContextMemoryLimits(
        recentTurns: 4,
        outcomes: 4,
        relevantRecords: 8,
        compactTextCharacters: 180,
        refreshEveryTurns: 3
    )

    static let openAI = AgentContextMemoryLimits(
        recentTurns: 10,
        outcomes: 8,
        relevantRecords: 20,
        compactTextCharacters: 700,
        refreshEveryTurns: nil
    )
}

actor LeadWhisperAgentMemory: AgentMemory {
    enum DraftOutcome: String, Sendable {
        case saved
        case cancelled
    }

    private var limits: AgentContextMemoryLimits
    private var recentTurns: [MemoryTurn] = []
    private var outcomes: [String] = []
    private var relevantRecords: [MemoryRecord] = []
    private var pendingDraftSummary: String?
    private var openClarification: String?
    private var turnsSinceSessionRefresh = 0

    init(limits: AgentContextMemoryLimits) {
        self.limits = limits
    }

    var shouldRefreshSession: Bool {
        guard let refreshEveryTurns = limits.refreshEveryTurns else { return false }
        return turnsSinceSessionRefresh >= refreshEveryTurns
    }

    var estimatedTokenCount: Int {
        roughTokenCount(context() ?? "")
    }

    func context() -> String? {
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

    func record(_ entry: AgentMemoryEntry) {
        switch entry {
        case .user(let text):
            appendTurn(role: "User", text: text)
            turnsSinceSessionRefresh += 1
        case .assistant(let text):
            appendTurn(role: "Assistant", text: text)
        case .system(let text):
            appendOutcome(text)
        }
    }

    func recordResultMetadata(_ result: AgentRunResult) {
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

    func recordOutcome(_ outcome: DraftOutcome) {
        let summary = pendingDraftSummary ?? "last draft"
        appendOutcome("\(outcome.rawValue) \(summary)")
        pendingDraftSummary = nil
        openClarification = nil
        turnsSinceSessionRefresh = limits.refreshEveryTurns ?? turnsSinceSessionRefresh
    }

    func markSessionRefreshed() {
        turnsSinceSessionRefresh = 0
    }

    func updateLimits(_ newLimits: AgentContextMemoryLimits) {
        limits = newLimits
        trimStoredCollections()
    }

    func reset() {
        recentTurns.removeAll(keepingCapacity: true)
        outcomes.removeAll(keepingCapacity: true)
        relevantRecords.removeAll(keepingCapacity: true)
        pendingDraftSummary = nil
        openClarification = nil
        turnsSinceSessionRefresh = 0
    }

    private var isEmpty: Bool {
        recentTurns.isEmpty &&
            outcomes.isEmpty &&
            relevantRecords.isEmpty &&
            pendingDraftSummary == nil &&
            openClarification == nil
    }

    private func appendTurn(role: String, text: String) {
        guard let compact = compactText(text) else { return }
        recentTurns.append(MemoryTurn(role: role, text: compact))
        if recentTurns.count > limits.recentTurns {
            recentTurns.removeFirst(recentTurns.count - limits.recentTurns)
        }
    }

    private func appendOutcome(_ outcome: String) {
        outcomes.append(compactText(outcome) ?? outcome)
        if outcomes.count > limits.outcomes {
            outcomes.removeFirst(outcomes.count - limits.outcomes)
        }
    }

    private func recordRelevantTargets(from changes: [ProposedChange]) {
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

        if relevantRecords.count > limits.relevantRecords {
            relevantRecords.removeFirst(relevantRecords.count - limits.relevantRecords)
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
        guard trimmed.count > limits.compactTextCharacters else { return trimmed }
        return "\(trimmed.prefix(limits.compactTextCharacters - 3))..."
    }

    private func trimStoredCollections() {
        if recentTurns.count > limits.recentTurns {
            recentTurns.removeFirst(recentTurns.count - limits.recentTurns)
        }
        if outcomes.count > limits.outcomes {
            outcomes.removeFirst(outcomes.count - limits.outcomes)
        }
        if relevantRecords.count > limits.relevantRecords {
            relevantRecords.removeFirst(relevantRecords.count - limits.relevantRecords)
        }
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
    nonisolated var memoryLabel: String {
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
    nonisolated var recordKind: String {
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

private nonisolated func roughTokenCount(_ text: String) -> Int {
    guard !text.isEmpty else { return 0 }
    return max(1, Int((Double(text.count) / 4).rounded(.up)))
}

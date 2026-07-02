import Foundation
import SwiftData
import SwiftUI

enum OpportunityStage: String, CaseIterable, Codable, Identifiable {
    case lead
    case qualified
    case proposalNeeded
    case proposalSent
    case won
    case lost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lead:
            "Lead"
        case .qualified:
            "Qualified"
        case .proposalNeeded:
            "Proposal Needed"
        case .proposalSent:
            "Proposal Sent"
        case .won:
            "Won"
        case .lost:
            "Lost"
        }
    }

    var systemImage: String {
        switch self {
        case .lead:
            "spark"
        case .qualified:
            "checkmark.seal"
        case .proposalNeeded:
            "doc.badge.plus"
        case .proposalSent:
            "paperplane"
        case .won:
            "trophy"
        case .lost:
            "xmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .lead:
            .blue
        case .qualified:
            .green
        case .proposalNeeded:
            .orange
        case .proposalSent:
            .indigo
        case .won:
            .mint
        case .lost:
            .red
        }
    }

    static func from(_ text: String?) -> OpportunityStage? {
        guard let text else { return nil }
        if let rawStage = OpportunityStage(rawValue: text) {
            return rawStage
        }

        let key = text.searchKey

        if key.contains("proposal sent") || key.contains("proposalsent") || key.contains("angebot gesendet") || key.contains("angebot positiv") {
            return .proposalSent
        }

        if key.contains("qualified") || key.contains("qualifiziert") {
            return .qualified
        }

        if key.contains("proposal needed") || key.contains("proposal") || key.contains("angebot erstellen") || key.contains("angebot benotigt") {
            return .proposalNeeded
        }

        if key.contains("won") || key.contains("gewonnen") {
            return .won
        }

        if key.contains("lost") || key.contains("verloren") {
            return .lost
        }

        if key.contains("lead") {
            return .lead
        }

        return nil
    }
}

enum FollowUpState: String, CaseIterable, Codable, Identifiable {
    case open
    case done
    case archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open:
            "Open"
        case .done:
            "Done"
        case .archived:
            "Archived"
        }
    }
}

@Model
final class Contact {
    @Attribute(.unique) var id: UUID
    var fullName: String
    var company: String
    var role: String
    var email: String
    var phone: String
    var notes: String
    var tags: [String]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        fullName: String,
        company: String = "",
        role: String = "",
        email: String = "",
        phone: String = "",
        notes: String = "",
        tags: [String] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.fullName = fullName
        self.company = company
        self.role = role
        self.email = email
        self.phone = phone
        self.notes = notes
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class Opportunity {
    @Attribute(.unique) var id: UUID
    var title: String
    var company: String
    var contactID: UUID?
    var stageRaw: String
    var estimatedValueEUR: Int?
    var budgetText: String
    var expectedStart: String
    var notes: String
    var tags: [String]
    var createdAt: Date
    var updatedAt: Date

    var stage: OpportunityStage {
        get { OpportunityStage(rawValue: stageRaw) ?? .lead }
        set { stageRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        title: String,
        company: String = "",
        contactID: UUID? = nil,
        stage: OpportunityStage = .lead,
        estimatedValueEUR: Int? = nil,
        budgetText: String = "",
        expectedStart: String = "",
        notes: String = "",
        tags: [String] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.company = company
        self.contactID = contactID
        self.stageRaw = stage.rawValue
        self.estimatedValueEUR = estimatedValueEUR
        self.budgetText = budgetText
        self.expectedStart = expectedStart
        self.notes = notes
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class Interaction {
    @Attribute(.unique) var id: UUID
    var contactID: UUID?
    var opportunityID: UUID?
    var summary: String
    var transcript: String
    var tags: [String]
    var occurredAt: Date

    init(
        id: UUID = UUID(),
        contactID: UUID? = nil,
        opportunityID: UUID? = nil,
        summary: String,
        transcript: String = "",
        tags: [String] = [],
        occurredAt: Date = .now
    ) {
        self.id = id
        self.contactID = contactID
        self.opportunityID = opportunityID
        self.summary = summary
        self.transcript = transcript
        self.tags = tags
        self.occurredAt = occurredAt
    }
}

@Model
final class FollowUpTask {
    @Attribute(.unique) var id: UUID
    var contactID: UUID?
    var opportunityID: UUID?
    var title: String
    var dueDate: Date?
    var dueDateText: String
    var notes: String
    var stateRaw: String
    var createdAt: Date
    var updatedAt: Date

    var state: FollowUpState {
        get { FollowUpState(rawValue: stateRaw) ?? .open }
        set { stateRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        contactID: UUID? = nil,
        opportunityID: UUID? = nil,
        title: String,
        dueDate: Date? = nil,
        dueDateText: String = "",
        notes: String = "",
        state: FollowUpState = .open,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.contactID = contactID
        self.opportunityID = opportunityID
        self.title = title
        self.dueDate = dueDate
        self.dueDateText = dueDateText
        self.notes = notes
        self.stateRaw = state.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class ActivityEvent {
    @Attribute(.unique) var id: UUID
    var title: String
    var detail: String
    var entityKind: String
    var entityID: UUID?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        detail: String = "",
        entityKind: String = "",
        entityID: UUID? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.entityKind = entityKind
        self.entityID = entityID
        self.createdAt = createdAt
    }
}

extension String {
    nonisolated var searchKey: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "ß", with: "ss")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated func containsSearch(_ needle: String) -> Bool {
        searchKey.contains(needle.searchKey)
    }
}

extension Array where Element == String {
    nonisolated func mergingTags(_ other: [String]) -> [String] {
        var seen = Set(map(\.searchKey))
        var merged = self

        for tag in other {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.searchKey
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(trimmed)
        }

        return merged
    }
}

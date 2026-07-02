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

import Foundation

extension DemoAgentParser {
    static func maxClarification(for key: String, snapshot: CRMDataSnapshot) -> ClarificationPrompt? {
        guard key.contains("max"),
              !key.contains("muller"),
              !key.contains("mueller"),
              !key.contains("schneider")
        else {
            return nil
        }

        let matches = snapshot.contacts.filter { $0.fullName.searchKey.contains("max") }
        guard matches.count > 1 else { return nil }

        return ClarificationPrompt(
            question: "I found two contacts named Max. Which one should I update?",
            options: matches.map { "\($0.fullName), \($0.company)" }
        )
    }

    static func selectedMaxContact(in key: String, snapshot: CRMDataSnapshot) -> CRMContactSnapshot? {
        guard key.contains("clarification answer") else { return nil }

        return snapshot.contacts.first { contact in
            key.contains(contact.fullName.searchKey) ||
                (!contact.company.searchKey.isEmpty && key.contains(contact.company.searchKey))
        }
    }

    static func detectContact(in key: String) -> (name: String, company: String) {
        if key.contains("sarah") || key.contains("bluepeak") {
            return ("Sarah Klein", "BluePeak")
        }
        if key.contains("julia") || key.contains("northwind") {
            return ("Julia", "Northwind")
        }
        if key.contains("anna") || key.contains("brightapps") {
            return ("Anna", "BrightApps")
        }
        if key.contains("max") || key.contains("acme") {
            return ("Max Mueller", "Acme Labs")
        }
        return ("New Contact", "New Company")
    }

    static func detectOpportunityTitle(in key: String) -> String {
        if key.contains("performance") || key.contains("startzeit") {
            return "Flutter performance support"
        }
        if key.contains("flutter") {
            return "Flutter app support"
        }
        if key.contains("offline") {
            return "iOS app with offline sync"
        }
        if key.contains("ios") || key.contains("native") {
            return "Native iOS app"
        }
        return "Client project support"
    }

    static func detectStage(in key: String) -> OpportunityStage? {
        if key.contains("proposal sent") || key.contains("angebot positiv") || key.contains("angebot gesendet") {
            return .proposalSent
        }
        if key.contains("qualified") || key.contains("qualifiziert") {
            return .qualified
        }
        if key.contains("proposal needed") || key.contains("angebot") {
            return .proposalNeeded
        }
        if key.contains("lost") || key.contains("verloren") {
            return .lost
        }
        return nil
    }

    static func detectTags(in key: String) -> [String] {
        var tags: [String] = []
        if key.contains("flutter") { tags.append("Flutter") }
        if key.contains("ios") || key.contains("native") { tags.append("iOS") }
        if key.contains("performance") || key.contains("startzeit") { tags.append("Performance") }
        if key.contains("offline") || key.contains("caching") { tags.append("Offline") }
        if tags.isEmpty { tags.append("Lead") }
        return tags
    }

    static func detectBudget(in key: String) -> Int? {
        if key.contains("20.000") || key.contains("20000") || key.contains("20,000") {
            return 20000
        }
        if key.contains("15") && key.contains("25") {
            return nil
        }
        return nil
    }

    static func detectBudgetText(in key: String) -> String {
        if key.contains("15") && key.contains("25") {
            return "EUR 15,000-25,000"
        }
        if let budget = detectBudget(in: key) {
            return "Approx. EUR \(budget)"
        }
        return ""
    }

    static func detectDueText(in key: String) -> String? {
        if key.contains("freitag") || key.contains("friday") { return "Friday" }
        if key.contains("montag") || key.contains("monday") { return "Monday" }
        if key.contains("donnerstag") || key.contains("thursday") { return "Thursday" }
        if key.contains("dienstag") || key.contains("tuesday") { return "next Tuesday" }
        if key.contains("morgen") || key.contains("tomorrow") { return "tomorrow" }
        return nil
    }

    static func detectExpectedStart(in key: String) -> String {
        if key.contains("august") { return "August" }
        if key.contains("september") { return "September" }
        if key.contains("next month") || key.contains("nachsten monat") || key.contains("nächsten monat") { return "Next month" }
        return ""
    }
}

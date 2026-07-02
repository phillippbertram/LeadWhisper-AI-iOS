import Foundation
import OSLog
import SwiftData

@MainActor
enum DemoDataSeeder {
    static func seedIfNeeded(in context: ModelContext) {
        let repository = CRMRepository(context: context)
        guard (try? repository.contacts().isEmpty) == true else {
            AppLog.data.debug("Demo seed skipped because contacts already exist")
            return
        }
        AppLog.data.info("Demo seed requested for empty store")
        seed(in: context)
    }

    static func seed(in context: ModelContext) {
        let repository = CRMRepository(context: context)
        if let existing = try? repository.contacts(),
           existing.contains(where: { $0.fullName.searchKey == "max mueller" || $0.fullName.searchKey == "max muller" }),
           existing.contains(where: { $0.fullName.searchKey == "max schneider" }) {
            context.insert(ActivityEvent(title: "Demo data already ready", detail: "Max ambiguity scenario is available.", entityKind: "system"))
            do {
                try context.save()
                AppLog.data.info("Demo seed skipped; ambiguity records already ready")
            } catch {
                AppLog.data.error("Demo seed marker save failed error=\(error.localizedDescription, privacy: .public)")
            }
            return
        }

        let maxMueller = Contact(
            fullName: "Max Mueller",
            company: "Acme Labs",
            notes: "Existing lead for native iOS work.",
            tags: ["iOS", "Proposal"]
        )
        let maxSchneider = Contact(
            fullName: "Max Schneider",
            company: "Northstar Studio",
            notes: "Past discovery call. Similar first name for ambiguity demo.",
            tags: ["Consulting"]
        )

        let acmeOpportunity = Opportunity(
            title: "Native iOS app",
            company: "Acme Labs",
            contactID: maxMueller.id,
            stage: .proposalNeeded,
            estimatedValueEUR: 32000,
            expectedStart: "September",
            notes: "Offline sync is a key concern.",
            tags: ["iOS", "Offline"]
        )

        let followUp = FollowUpTask(
            contactID: maxMueller.id,
            opportunityID: acmeOpportunity.id,
            title: "Send proposal to Max Mueller",
            dueDate: DueDateResolver.date(from: "Thursday"),
            dueDateText: "Thursday",
            notes: "Include architecture note for offline sync."
        )

        context.insert(maxMueller)
        context.insert(maxSchneider)
        context.insert(acmeOpportunity)
        context.insert(followUp)
        context.insert(ActivityEvent(title: "Demo data seeded", detail: "Max ambiguity scenario is ready.", entityKind: "system"))
        do {
            try context.save()
            AppLog.data.info("Demo data seeded contacts=2 opportunities=1 followUps=1")
        } catch {
            AppLog.data.error("Demo seed save failed error=\(error.localizedDescription, privacy: .public)")
        }
    }
}

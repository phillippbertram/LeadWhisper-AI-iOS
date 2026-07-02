import OSLog
import SwiftData
import SwiftUI

@main
struct LeadWhisperApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Contact.self,
            Opportunity.self,
            Interaction.self,
            FollowUpTask.self,
            ActivityEvent.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            AppLog.app.info("SwiftData ModelContainer initialized")
            return container
        } catch {
            AppLog.app.error("Could not create SwiftData ModelContainer error=\(error.localizedDescription, privacy: .public)")
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}

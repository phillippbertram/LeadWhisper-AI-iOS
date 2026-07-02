import OSLog
import SwiftData
import SwiftUI

@main
@MainActor
struct LeadWhisperApp: App {
    let sharedModelContainer: ModelContainer
    private let crmRepository: CRMRepository

    init() {
        let container = Self.makeSharedModelContainer()
        sharedModelContainer = container
        crmRepository = CRMRepository(context: container.mainContext)
    }

    private static func makeSharedModelContainer() -> ModelContainer {
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
            // The store holds reseedable demo data only, so an incompatible
            // schema (e.g. after a model change without a migration plan) is
            // recovered by wiping the store and starting fresh.
            AppLog.app.error("Could not create SwiftData ModelContainer, wiping store error=\(error.localizedDescription, privacy: .public)")
            let storeURL = modelConfiguration.url
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
            }

            do {
                let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
                AppLog.app.warning("SwiftData store recreated after wiping incompatible data")
                return container
            } catch {
                AppLog.app.error("Could not recreate SwiftData ModelContainer error=\(error.localizedDescription, privacy: .public)")
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.crmRepository, crmRepository)
        }
        .modelContainer(sharedModelContainer)
    }
}

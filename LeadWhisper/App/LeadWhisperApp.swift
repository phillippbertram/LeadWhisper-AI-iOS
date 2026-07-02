import FactoryKit
import SwiftData
import SwiftUI

@main
@MainActor
struct LeadWhisperApp: App {
    let sharedModelContainer: ModelContainer

    init() {
        let container = Container.shared.modelContainer()
        sharedModelContainer = container
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}

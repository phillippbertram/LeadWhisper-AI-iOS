import SwiftData
import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Today", systemImage: "calendar") {
                TodayView()
            }

            Tab("Contacts", systemImage: "person.2") {
                ContactsView()
            }

            Tab("Opportunities", systemImage: "chart.line.uptrend.xyaxis") {
                OpportunitiesView()
            }

            Tab("Agent", systemImage: "sparkles") {
                AgentView()
            }

            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Contact.self, Opportunity.self, Interaction.self, FollowUpTask.self, ActivityEvent.self], inMemory: true)
}

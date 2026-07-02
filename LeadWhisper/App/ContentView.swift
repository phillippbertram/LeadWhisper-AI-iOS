import SwiftData
import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem {
                    Label("Today", systemImage: "calendar")
                }

            ContactsView()
                .tabItem {
                    Label("Contacts", systemImage: "person.2")
                }

            OpportunitiesView()
                .tabItem {
                    Label("Opportunities", systemImage: "chart.line.uptrend.xyaxis")
                }

            AgentView()
                .tabItem {
                    Label("Agent", systemImage: "sparkles")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Contact.self, Opportunity.self, Interaction.self, FollowUpTask.self, ActivityEvent.self], inMemory: true)
}

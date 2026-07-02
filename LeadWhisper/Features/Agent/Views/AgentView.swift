import SwiftUI

struct AgentView: View {
    var body: some View {
        NavigationStack {
            AgentComposerView(showTitle: false)
                .navigationTitle("Agent")
        }
    }
}

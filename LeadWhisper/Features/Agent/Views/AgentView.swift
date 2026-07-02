import SwiftUI

struct AgentView: View {
    var body: some View {
        NavigationStack {
            AgentComposerView()
                .navigationTitle("Agent")
        }
    }
}

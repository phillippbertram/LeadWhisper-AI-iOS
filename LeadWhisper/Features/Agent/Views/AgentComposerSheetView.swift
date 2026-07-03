import SwiftUI

struct AgentComposerSheetView: View {
    @Environment(\.dismiss) private var dismiss
    var initialPrompt: String?

    var body: some View {
        NavigationStack {
            AgentComposerView(initialPrompt: initialPrompt)
                .navigationTitle("Agent")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.regularMaterial, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") {
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
    }
}

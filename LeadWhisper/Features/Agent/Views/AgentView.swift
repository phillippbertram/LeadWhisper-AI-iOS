import SwiftUI

struct AgentView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isComposerVisible = false

    var body: some View {
        NavigationStack {
            AgentComposerView()
                .opacity(composerOpacity)
                .offset(y: composerOffset)
                .navigationTitle("Agent")
                .onAppear(perform: showComposer)
                .onDisappear {
                    isComposerVisible = false
                }
        }
    }

    private var composerOpacity: Double {
        accessibilityReduceMotion || isComposerVisible ? 1 : 0
    }

    private var composerOffset: CGFloat {
        guard !accessibilityReduceMotion else { return 0 }
        return isComposerVisible ? 0 : 8
    }

    private func showComposer() {
        guard !accessibilityReduceMotion else {
            isComposerVisible = true
            return
        }

        withAnimation(.snappy(duration: 0.26, extraBounce: 0.02)) {
            isComposerVisible = true
        }
    }
}

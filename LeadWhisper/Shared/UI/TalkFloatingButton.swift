import SwiftUI

struct TalkFloatingButton: View {
    let open: () -> Void

    var body: some View {
        Button {
            open()
        } label: {
            Label("Agent", systemImage: "keyboard")
                .font(.headline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .accessibilityLabel("Open LeadWhisper agent")
    }
}

extension View {
    func talkFloatingAction(open: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .bottom, alignment: .trailing) {
            TalkFloatingButton(open: open)
                .padding(.trailing, 18)
                .padding(.bottom, 10)
        }
    }
}

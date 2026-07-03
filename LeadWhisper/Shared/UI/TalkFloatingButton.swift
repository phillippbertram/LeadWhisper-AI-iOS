import SwiftUI

struct TalkFloatingButton: View {
    let open: () -> Void

    var body: some View {
        Button {
            open()
        } label: {
            ZStack {
                Circle()
                    .fill(.regularMaterial)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .cyan.opacity(0.88),
                                .blue,
                                .green.opacity(0.84)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .padding(5)

                Circle()
                    .strokeBorder(.white.opacity(0.16), lineWidth: 0.8)

                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .cyan.opacity(0.58),
                                .white.opacity(0.2),
                                .green.opacity(0.44)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.2
                    )
                    .padding(5)

                Image(systemName: "sparkles")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.hierarchical)
            }
            .frame(width: 58, height: 58)
            .contentShape(Circle())
        }
        .buttonStyle(TalkFloatingButtonStyle())
        .accessibilityLabel("Open LeadWhisper agent")
        .accessibilityHint("Opens the composer to capture a lead update.")
    }
}

private struct TalkFloatingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .shadow(
                color: .blue.opacity(configuration.isPressed ? 0.16 : 0.24),
                radius: configuration.isPressed ? 10 : 18,
                x: 0,
                y: configuration.isPressed ? 5 : 9
            )
            .shadow(
                color: .black.opacity(configuration.isPressed ? 0.16 : 0.22),
                radius: configuration.isPressed ? 10 : 16,
                x: 0,
                y: configuration.isPressed ? 5 : 9
            )
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

extension View {
    func talkFloatingAction(open: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .bottom, alignment: .trailing) {
            TalkFloatingButton(open: open)
                .padding(.trailing, 20)
                .padding(.bottom, 12)
        }
    }
}

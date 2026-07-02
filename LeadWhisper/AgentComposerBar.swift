import BeamBorder
import SwiftUI

struct TalkFloatingButton: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let open: () -> Void

    private let cornerRadius: CGFloat = 24

    private var beamConfiguration: BeamBorderConfiguration {
        BeamBorderConfiguration(
            border: .white.opacity(0.9),
            showsBaseBorder: true,
            beamColors: [.cyan, .blue, .mint, .purple],
            beamDirection: .both,
            beamBlur: 16,
            cornerRadius: cornerRadius,
            borderLineWidth: 0.8,
            baseBorderLineWidth: 0.9,
            animationDuration: 2.8
        )
    }

    var body: some View {
        Button {
            open()
        } label: {
            Label("Talk", systemImage: "mic.fill")
                .font(.headline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [.blue, .indigo],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(accessibilityReduceMotion ? 0.45 : 0.24), lineWidth: accessibilityReduceMotion ? 1.2 : 0.7)
                }
                .beamBorder(beamConfiguration, isEnabled: !accessibilityReduceMotion)
                .shadow(color: .blue.opacity(0.28), radius: 16, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Talk to LeadWhisper")
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

struct AgentComposerSheetView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AgentComposerView(showTitle: true)
                .navigationTitle("Agent")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") {
                            dismiss()
                        }
                    }
                }
        }
    }
}

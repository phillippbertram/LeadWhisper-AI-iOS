import SwiftUI

/// A user-presentable wrapper around an error thrown by a CRM operation.
///
/// Using an `Identifiable` value lets views drive a single alert from optional
/// state instead of silently discarding failures with `try?`.
struct PresentableError: Identifiable {
    let id = UUID()
    let message: String

    init(_ error: Error) {
        message = error.localizedDescription
    }

    init(message: String) {
        self.message = message
    }
}

extension View {
    /// Presents a standard alert whenever `error` becomes non-nil.
    func crmErrorAlert(_ error: Binding<PresentableError?>) -> some View {
        alert(
            "Something went wrong",
            isPresented: Binding(
                get: { error.wrappedValue != nil },
                set: { if !$0 { error.wrappedValue = nil } }
            ),
            presenting: error.wrappedValue
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { presentable in
            Text(presentable.message)
        }
        .onChange(of: error.wrappedValue?.id) { _, newValue in
            if newValue != nil {
                HapticFeedback.play(.error)
            }
        }
    }
}

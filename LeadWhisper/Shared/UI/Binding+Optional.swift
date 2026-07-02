import SwiftUI

extension Binding where Value == Bool {
    init<Wrapped>(isPresenting optional: Binding<Wrapped?>) {
        self.init(
            get: { optional.wrappedValue != nil },
            set: { isPresented in
                if !isPresented {
                    optional.wrappedValue = nil
                }
            }
        )
    }
}

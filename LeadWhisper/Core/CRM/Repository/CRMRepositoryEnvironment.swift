import SwiftData
import SwiftUI

extension EnvironmentValues {
    @Entry var crmRepository: CRMRepository?
}

@MainActor
extension Optional where Wrapped == CRMRepository {
    func repository(fallback context: ModelContext) -> CRMRepository {
        self ?? CRMRepository(context: context)
    }
}

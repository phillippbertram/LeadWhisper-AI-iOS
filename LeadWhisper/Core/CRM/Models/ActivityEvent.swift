import Foundation
import SwiftData

@Model
final class ActivityEvent {
    @Attribute(.unique) var id: UUID
    var title: String
    var detail: String
    var entityKind: String
    var entityID: UUID?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        detail: String = "",
        entityKind: String = "",
        entityID: UUID? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.entityKind = entityKind
        self.entityID = entityID
        self.createdAt = createdAt
    }
}

import Foundation
import SwiftData

@Model
final class Contact {
    @Attribute(.unique) var id: UUID
    var fullName: String
    var company: String
    var role: String
    var email: String
    var phone: String
    var notes: String
    var tags: [String]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        fullName: String,
        company: String = "",
        role: String = "",
        email: String = "",
        phone: String = "",
        notes: String = "",
        tags: [String] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.fullName = fullName
        self.company = company
        self.role = role
        self.email = email
        self.phone = phone
        self.notes = notes
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

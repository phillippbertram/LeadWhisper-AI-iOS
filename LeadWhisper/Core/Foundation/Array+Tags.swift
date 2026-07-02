import Foundation

extension Array where Element == String {
    nonisolated func mergingTags(_ other: [String]) -> [String] {
        var seen = Set(map(\.searchKey))
        var merged = self

        for tag in other {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.searchKey
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(trimmed)
        }

        return merged
    }
}

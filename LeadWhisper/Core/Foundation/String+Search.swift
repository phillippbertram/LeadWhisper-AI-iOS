import Foundation

extension String {
    nonisolated var searchKey: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "ß", with: "ss")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated func containsSearch(_ needle: String) -> Bool {
        searchKey.contains(needle.searchKey)
    }
}

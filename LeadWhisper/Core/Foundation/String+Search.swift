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

struct FuzzySearch: Sendable {
    struct Field: Sendable {
        let value: String
        let weight: Int

        static func primary(_ value: String) -> Field {
            Field(value: value, weight: 120)
        }

        static func secondary(_ value: String) -> Field {
            Field(value: value, weight: 60)
        }
    }

    struct Result<Element> {
        let item: Element
        let score: Int
        let kind: MatchKind
    }

    enum MatchKind: Int {
        case fuzzy = 1
        case tokens = 2
        case phrase = 3
    }

    static let defaultNoiseWords: Set<String> = [
        "am", "an", "and", "at", "bei", "das", "der", "die", "for", "fur",
        "im", "in", "mit", "of", "on", "the", "to", "und", "von", "with", "zu"
    ]

    let noiseWords: Set<String>

    init(noiseWords: Set<String> = Self.defaultNoiseWords) {
        self.noiseWords = noiseWords
    }

    func results<Element>(
        in records: [Element],
        matching query: String,
        limit: Int,
        fields: (Element) -> [Field]
    ) -> [Element] {
        rankedResults(in: records, matching: query, limit: limit, fields: fields)
            .map(\.item)
    }

    func rankedResults<Element>(
        in records: [Element],
        matching query: String,
        limit: Int,
        fields: (Element) -> [Field]
    ) -> [Result<Element>] {
        let key = query.searchKey
        let tokens = queryTokens(from: key)
        guard !key.isEmpty, limit > 0 else { return [] }
        guard !tokens.isEmpty || (key.count >= 3 && !noiseWords.contains(key)) else { return [] }

        return records.enumerated()
            .compactMap { offset, record -> Candidate<Element>? in
                guard let match = match(queryKey: key, tokens: tokens, fields: fields(record)) else { return nil }
                return Candidate(item: record, match: match, offset: offset)
            }
            .sorted { lhs, rhs in
                if lhs.match.kind != rhs.match.kind {
                    return lhs.match.kind.rawValue > rhs.match.kind.rawValue
                }
                if lhs.match.score != rhs.match.score {
                    return lhs.match.score > rhs.match.score
                }
                return lhs.offset < rhs.offset
            }
            .prefix(limit)
            .map {
                Result(item: $0.item, score: $0.match.score, kind: $0.match.kind)
            }
    }

    private func match(queryKey: String, tokens: [String], fields: [Field]) -> Match? {
        let searchableFields = fields
            .map { field in (key: field.value.searchKey, weight: field.weight) }
            .filter { !$0.key.isEmpty }
        guard !searchableFields.isEmpty else { return nil }

        let combinedKey = searchableFields.map(\.key).joined(separator: " ")
        if combinedKey.contains(queryKey) {
            let fieldWeight = searchableFields
                .filter { $0.key.contains(queryKey) }
                .map(\.weight)
                .max() ?? 0
            return Match(kind: .phrase, score: 10_000 + fieldWeight + queryKey.count)
        }

        if !tokens.isEmpty {
            var tokenScore = 0
            for token in tokens {
                let bestFieldScore = searchableFields
                    .filter { $0.key.contains(token) }
                    .map(\.weight)
                    .max()
                guard let bestFieldScore else {
                    tokenScore = 0
                    break
                }
                tokenScore += bestFieldScore + token.count
            }
            if tokenScore > 0 {
                return Match(kind: .tokens, score: 6_000 + tokenScore)
            }
        }

        let compactQuery = queryKey.compactSearchKey
        guard compactQuery.count >= 5 else { return nil }

        let fuzzyScore = fuzzySubsequenceScore(query: compactQuery, candidate: combinedKey.compactSearchKey)
        guard fuzzyScore >= fuzzyThreshold(for: compactQuery) else { return nil }
        return Match(kind: .fuzzy, score: 3_000 + fuzzyScore)
    }

    private func queryTokens(from key: String) -> [String] {
        var seen: Set<String> = []
        var tokens: [String] = []

        for part in key.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let token = String(part)
            guard token.count > 1, !noiseWords.contains(token), !seen.contains(token) else {
                continue
            }
            seen.insert(token)
            tokens.append(token)
        }

        return tokens
    }

    private func fuzzySubsequenceScore(query: String, candidate: String) -> Int {
        let queryCharacters = Array(query)
        guard !queryCharacters.isEmpty else { return 0 }

        var queryIndex = 0
        var currentRun = 0
        var score = 0

        for candidateCharacter in candidate {
            guard queryIndex < queryCharacters.count else { break }
            if candidateCharacter == queryCharacters[queryIndex] {
                queryIndex += 1
                currentRun += 1
                score += currentRun
            } else {
                currentRun = 0
            }
        }

        return queryIndex == queryCharacters.count ? score : 0
    }

    private func fuzzyThreshold(for query: String) -> Int {
        query.count + max(4, query.count / 2)
    }
}

private struct Match {
    let kind: FuzzySearch.MatchKind
    let score: Int
}

private struct Candidate<Element> {
    let item: Element
    let match: Match
    let offset: Int
}

private extension String {
    var compactSearchKey: String {
        searchKey.filter { $0.isLetter || $0.isNumber }
    }
}

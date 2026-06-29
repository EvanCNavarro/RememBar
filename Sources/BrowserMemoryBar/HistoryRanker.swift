import Foundation

enum HistoryRanker {
    static func search(
        rows: [HistoryItem],
        query: String,
        refinements: [String] = [],
        limit: Int,
        aliases: AliasGroups = .empty
    ) -> [HistoryItem] {
        searchRanked(rows: rows, query: query, refinements: refinements, limit: limit, aliases: aliases)
            .map(\.item)
    }

    static func searchRanked(
        rows: [HistoryItem],
        query: String,
        refinements: [String] = [],
        limit: Int,
        aliases: AliasGroups = .empty
    ) -> [RankedHistoryItem] {
        let terms = tokenize(query)
        let refinementTerms = tokenize(refinements.joined(separator: " "))
        let wantsYouTube = (terms + refinementTerms).contains { $0 == "youtube" || $0 == "youtu" }
        let contentTerms = terms.filter { $0 != "youtube" && $0 != "youtu" }
        let contentRefinementTerms = refinementTerms.filter { $0 != "youtube" && $0 != "youtu" }
        // A group is one logical term: match per slot so aliases never inflate the AND-threshold.
        let contentSlots = aliases.slots(contentTerms)
        return rows
            .compactMap { row -> (HistoryItem, Int)? in
                let score = score(
                    row: row,
                    slots: contentSlots,
                    refinementTerms: contentRefinementTerms,
                    query: query,
                    wantsYouTube: wantsYouTube
                )
                return score > 0 ? (row, score) : nil
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.visitedAt > rhs.0.visitedAt
                }
                return lhs.1 > rhs.1
            }
            .prefix(limit)
            .map { RankedHistoryItem(item: $0.0, score: $0.1) }
    }

    static func tokenize(_ text: String) -> [String] {
        MemorySearchTokenizer.tokenize(text)
    }

    private static func score(
        row: HistoryItem,
        slots: [[String]],
        refinementTerms: [String],
        query: String,
        wantsYouTube: Bool
    ) -> Int {
        if wantsYouTube, !isYouTube(row.url) {
            return 0
        }
        guard !slots.isEmpty else {
            return wantsYouTube ? 30 + youtubeVideoScore(row.url) : 1
        }
        let urlText = row.url.absoluteString.lowercased()
        let titleTerms = Set(tokenize(row.title))
        let urlTerms = Set(tokenize(urlText))
        let contextTerms = Set(tokenize("\(row.browser.displayName) \(row.profile)"))
        let rowTerms = titleTerms.union(urlTerms).union(contextTerms)
        var score = 0
        var matched = 0

        // One match per slot (a group counts once), so the AND-threshold stays on the typed-term
        // count. Score by the slot's strongest field across any present variant (title > url > rest).
        for slot in slots {
            let present = slot.filter { rowTerms.contains($0) }
            guard !present.isEmpty else { continue }
            matched += 1
            if present.contains(where: { titleTerms.contains($0) }) {
                score += 70
            } else if present.contains(where: { urlTerms.contains($0) }) {
                score += 55
            } else {
                score += 35
            }
        }

        guard matched >= requiredContentMatches(for: slots.count) else { return 0 }
        if wantsYouTube {
            score += 30
            score += youtubeVideoScore(row.url)
        }
        for term in refinementTerms where rowTerms.contains(term) {
            score += urlTerms.contains(term) ? 20 : 15
        }
        score += min(20, query.count)
        return score
    }

    private static func requiredContentMatches(for termCount: Int) -> Int {
        guard termCount > 3 else { return termCount }
        return max(2, Int(ceil(Double(termCount) * 0.6)))
    }

    private static func isYouTube(_ url: URL) -> Bool {
        url.isYouTubeURL
    }

    private static func youtubeVideoScore(_ url: URL) -> Int {
        let host = url.normalizedHost
        if host == "youtu.be" {
            return 55
        }
        guard host == "youtube.com" || host.hasSuffix(".youtube.com") else { return 0 }
        if url.path == "/watch" {
            return 55
        }
        if url.path.hasPrefix("/shorts/") {
            return 35
        }
        return 0
    }
}

struct RankedHistoryItem: Equatable, Sendable {
    let item: HistoryItem
    let score: Int
}

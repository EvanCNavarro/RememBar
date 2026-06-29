import Foundation

/// User-curated "families" of interchangeable search terms. Searching any member of a group also
/// finds files named after the others — e.g. a group `["evan", "ecn", "navarro"]` makes a search
/// for `evan` surface `ECN_*` files too.
///
/// This is the single authority for term expansion: every provider that wants alias behaviour calls
/// `expand(_:)` rather than reimplementing it. Groups are loaded from a plain `aliases.json` (an
/// array of string arrays); a missing or malformed file yields no expansion, never a crash.
struct AliasGroups: Equatable, Sendable {
    /// Each inner array is a set of interchangeable terms, lowercased, ≥2 members, members ≥2 chars.
    private let groups: [[String]]

    static let empty = AliasGroups(groups: [])

    // Bounds so a pathological config (one giant group, every term aliased) can't explode the mdfind
    // predicate string or the per-term ranker loop.
    private static let maxMembersPerGroup = 64
    private static let maxExpandedTerms = 256

    init(groups: [[String]]) {
        self.groups = groups
            .map { group -> [String] in
                var seen = Set<String>()
                // ≥2 chars mirrors the tokenizer (a 1-char member like "e" would mdfind-match
                // "*e*" — i.e. everything); dedupe within the group; cap fan-out.
                let cleaned = group.map { $0.lowercased() }.filter { $0.count > 1 && seen.insert($0).inserted }
                return Array(cleaned.prefix(Self.maxMembersPerGroup))
            }
            .filter { $0.count > 1 } // a group of fewer than two terms expands to nothing
    }

    /// Each input term, followed by every term in any group it belongs to. Order-preserving and
    /// deduped, so the resulting query is deterministic. Input terms are assumed already lowercased
    /// (the tokenizer lowercases); lowercasing here too keeps it safe if called directly.
    func expand(_ terms: [String]) -> [String] {
        guard !groups.isEmpty else { return terms }
        var result: [String] = []
        var seen = Set<String>()
        for term in terms {
            for candidate in [term.lowercased()] + members(of: term) where seen.insert(candidate).inserted {
                result.append(candidate)
                if result.count >= Self.maxExpandedTerms { return result }
            }
        }
        return result
    }

    private func members(of term: String) -> [String] {
        let lower = term.lowercased()
        return groups.filter { $0.contains(lower) }.flatMap { $0 }
    }

    /// Load alias groups from `aliases.json` (an array of string arrays). Missing or malformed →
    /// `.empty`, so a bad config never breaks search.
    static func load(from url: URL) -> AliasGroups {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([[String]].self, from: data) else {
            return .empty
        }
        return AliasGroups(groups: raw)
    }
}

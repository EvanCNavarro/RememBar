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

    /// Each input term as a "slot": the term plus every member of any group it belongs to, deduped
    /// within the slot and bounded. A group is ONE logical term — callers with AND-style thresholds
    /// (e.g. "match ≥N of the typed terms") MUST match per slot, not per flattened variant, or an
    /// alias group inflates the term count and breaks the threshold.
    func slots(_ terms: [String]) -> [[String]] {
        terms.map { term in
            var seen = Set<String>()
            let variants = [term.lowercased()] + members(of: term)
            return Array(variants.filter { seen.insert($0).inserted }.prefix(Self.maxMembersPerGroup))
        }
    }

    /// Flat union of `slots(_:)` — every term + alias member, order-preserving, deduped, bounded.
    /// Right for OR-style matching and for building the mdfind fetch query.
    func expand(_ terms: [String]) -> [String] {
        guard !groups.isEmpty else { return terms }
        var result: [String] = []
        var seen = Set<String>()
        for slot in slots(terms) {
            for candidate in slot where seen.insert(candidate).inserted {
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

    /// The sanitized groups, for an editor to render/round-trip. This is the model's real state —
    /// lowercased, ≥2-char members, ≥2-member groups — NOT the user's raw keystrokes (an editor keeps
    /// its own draft buffer for in-progress input; see the term-families UI).
    var families: [[String]] {
        groups
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

    /// Persist the sanitized groups to `aliases.json` as the same array-of-arrays `load(from:)` reads.
    /// Written atomically so a crash mid-save can't leave a truncated/half-written config that would
    /// silently degrade to `.empty` on next launch.
    func save(to url: URL) throws {
        let data = try JSONEncoder().encode(groups)
        try data.write(to: url, options: .atomic)
    }
}

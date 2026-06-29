@testable import BrowserMemoryBar
import Foundation
import Testing

@Suite("Alias Groups")
struct AliasGroupsTests {
    private let family = AliasGroups(groups: [["evan", "carlos", "navarro", "ecn"]])

    @Test("any member expands to the whole family")
    func expandsBidirectionally() {
        #expect(family.expand(["evan"]) == ["evan", "carlos", "navarro", "ecn"])
        #expect(family.expand(["ecn"]) == ["ecn", "evan", "carlos", "navarro"])
    }

    @Test("non-member terms pass through untouched, order + dedupe preserved")
    func passthroughAndOrder() {
        #expect(family.expand(["resume"]) == ["resume"])
        #expect(family.expand(["evan", "resume"]) == ["evan", "carlos", "navarro", "ecn", "resume"])
        // a query that already names two members must not duplicate the family
        #expect(family.expand(["evan", "ecn"]) == ["evan", "carlos", "navarro", "ecn"])
    }

    @Test("matching is case-insensitive")
    func caseInsensitive() {
        #expect(AliasGroups(groups: [["Evan", "ECN"]]).expand(["EVAN"]) == ["evan", "ecn"])
    }

    @Test("a term in two groups unions both")
    func multiGroupUnion() {
        let sut = AliasGroups(groups: [["evan", "ecn"], ["evan", "navarro"]])
        #expect(sut.expand(["evan"]) == ["evan", "ecn", "navarro"])
    }

    @Test("footguns are filtered: 1-char members and <2-member groups are dropped")
    func footgunFilters() {
        // "e" would mdfind-match "*e*" (everything) — must be stripped
        #expect(AliasGroups(groups: [["evan", "e", "ecn"]]).expand(["evan"]) == ["evan", "ecn"])
        // a single-member group expands to nothing
        #expect(AliasGroups(groups: [["evan"]]).expand(["evan"]) == ["evan"])
    }

    @Test("empty groups are a pure pass-through")
    func emptyIsIdentity() {
        #expect(AliasGroups.empty.expand(["evan", "ecn"]) == ["evan", "ecn"])
    }

    @Test("load: valid JSON parses; missing or malformed yields empty (never crashes)")
    func loading() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let valid = dir.appendingPathComponent("valid.json")
        try Data(#"[["evan","ecn"],["mom","mother"]]"#.utf8).write(to: valid)
        #expect(AliasGroups.load(from: valid).expand(["mom"]) == ["mom", "mother"])

        let malformed = dir.appendingPathComponent("bad.json")
        try Data("{ not valid json".utf8).write(to: malformed)
        #expect(AliasGroups.load(from: malformed) == .empty)

        #expect(AliasGroups.load(from: dir.appendingPathComponent("missing.json")) == .empty)
    }

    @Test("the file query plan expands entity terms AND the mdfind query through aliases")
    func planIntegration() {
        let aliases = AliasGroups(groups: [["evan", "ecn"]])
        let plan = SpotlightFileQueryPlan(query: "evan", refinements: [], aliases: aliases)
        #expect(plan.entityTerms == ["evan", "ecn"]) // ranker now scores ECN matches as entity hits
        #expect(plan.query.contains("*evan*"))
        #expect(plan.query.contains("*ecn*")) // mdfind now fetches ECN-named files

        // Without aliases, the query is unchanged (default behaviour preserved).
        let plain = SpotlightFileQueryPlan(query: "evan", refinements: [])
        #expect(plain.entityTerms == ["evan"])
        #expect(!plain.query.contains("*ecn*"))
    }
}

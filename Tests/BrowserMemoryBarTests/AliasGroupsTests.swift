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

    @Test("oversized groups are bounded so a pathological config can't explode the query")
    func fanOutBounded() {
        let huge = (0..<500).map { "term\($0)" }
        #expect(AliasGroups(groups: [huge]).expand(["term0"]).count <= 64) // capped to maxMembersPerGroup
    }

    @Test("an alias member that is itself a descriptor still expands from its alias")
    func descriptorMemberEdge() {
        // typing "au" pulls in "gold"; expansion is term-level, the plan decides descriptor-ness
        #expect(AliasGroups(groups: [["au", "gold"]]).expand(["au"]) == ["au", "gold"])
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

    // MARK: P0 — serialization (the editor needs to READ groups back and SAVE them)

    @Test("families accessor exposes the sanitized groups for an editor to render")
    func familiesAccessor() {
        // lowercased, 1-char member dropped, <2-member group dropped — mirrors init sanitization
        let sut = AliasGroups(groups: [["Evan", "ECN", "x"], ["mom", "mother"], ["solo"]])
        #expect(sut.families == [["evan", "ecn"], ["mom", "mother"]])
        #expect(AliasGroups.empty.families == [])
    }

    @Test("save then load round-trips through disk (sanitized value preserved)")
    func saveLoadRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("aliases.json")

        let original = AliasGroups(groups: [["evan", "ecn", "navarro"], ["mom", "mother"]])
        try original.save(to: url)
        #expect(AliasGroups.load(from: url) == original)
    }

    @Test("save writes a valid JSON array-of-arrays (compatible with the existing on-disk format)")
    func saveWritesArrayOfArrays() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("aliases.json")

        try AliasGroups(groups: [["evan", "ecn"]]).save(to: url)
        let raw = try JSONDecoder().decode([[String]].self, from: Data(contentsOf: url))
        #expect(raw == [["evan", "ecn"]])
    }

    @Test("save overwrites prior contents cleanly (no stale bytes appended)")
    func saveOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("aliases.json")

        try AliasGroups(groups: [["alpha", "beta"], ["gamma", "delta"]]).save(to: url)
        try AliasGroups(groups: [["one", "two"]]).save(to: url) // shorter — would leave tail if non-atomic overwrite
        #expect(AliasGroups.load(from: url) == AliasGroups(groups: [["one", "two"]]))
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

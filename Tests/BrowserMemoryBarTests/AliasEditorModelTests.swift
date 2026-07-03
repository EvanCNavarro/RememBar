@testable import BrowserMemoryBar
import Foundation
import Testing

@MainActor
@Suite("Alias Editor Model")
struct AliasEditorModelTests {
    private func tempCatalog() throws -> (AliasCatalog, () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("aliases.json")
        return (AliasCatalog(url: url), { try? FileManager.default.removeItem(at: dir) })
    }

    @Test("seeds its editable rows from the catalog's current families")
    func seedsFromCatalog() throws {
        let (catalog, cleanup) = try tempCatalog(); defer { cleanup() }
        catalog.update(families: [["evan", "ecn"], ["mom", "mother"]])
        let model = AliasEditorModel(catalog: catalog)
        #expect(model.rows.map(\.words) == [["evan", "ecn"], ["mom", "mother"]])
    }

    @Test("adding a word to a family commits live to the catalog (visible to search next call)")
    func addWordCommitsLive() throws {
        let (catalog, cleanup) = try tempCatalog(); defer { cleanup() }
        let model = AliasEditorModel(catalog: catalog)
        let row = model.addRow()
        model.addWord("evan", toRow: row)
        model.addWord("ecn", toRow: row)
        #expect(catalog.snapshot.expand(["evan"]) == ["evan", "ecn"])
    }

    // THE audit's core correction: a half-built (1-member) family must SURVIVE in the editor draft —
    // it must not be deleted out from under the user by the model's <2-member sanitization — while
    // still (correctly) being inactive for search until it has a 2nd word.
    @Test("a one-word family survives in the draft but is inactive for search until a second word")
    func oneWordRowSurvivesInDraft() throws {
        let (catalog, cleanup) = try tempCatalog(); defer { cleanup() }
        let model = AliasEditorModel(catalog: catalog)
        let row = model.addRow()
        model.addWord("solo", toRow: row)
        // Draft keeps the row visible for continued editing...
        #expect(model.rows.map(\.words) == [["solo"]])
        #expect(model.isActive(row) == false)
        // ...but the engine does not use a <2-member group.
        #expect(catalog.snapshot.families == [])
        // Second word activates it, live.
        model.addWord("alone", toRow: row)
        #expect(model.isActive(row) == true)
        #expect(catalog.snapshot.expand(["solo"]) == ["solo", "alone"])
    }

    @Test("word input is trimmed and de-duplicated within a family; blanks are ignored")
    func autoStripAndDedupe() throws {
        let (catalog, cleanup) = try tempCatalog(); defer { cleanup() }
        let model = AliasEditorModel(catalog: catalog)
        let row = model.addRow()
        model.addWord("  Evan  ", toRow: row)
        model.addWord("evan", toRow: row)   // duplicate (case-insensitive) — ignored
        model.addWord("   ", toRow: row)     // blank — ignored
        model.addWord("ECN", toRow: row)
        #expect(model.rows.first?.words == ["Evan", "ECN"]) // raw case preserved in the draft
    }

    @Test("removing a word, and removing a whole family, update the draft and the catalog")
    func removeWordAndRow() throws {
        let (catalog, cleanup) = try tempCatalog(); defer { cleanup() }
        catalog.update(families: [["evan", "ecn", "navarro"], ["mom", "mother"]])
        let model = AliasEditorModel(catalog: catalog)
        let first = try #require(model.rows.first?.id)
        model.removeWord("navarro", fromRow: first)
        #expect(model.rows.first?.words == ["evan", "ecn"])

        model.removeRow(first)
        #expect(model.rows.map(\.words) == [["mom", "mother"]])
        #expect(catalog.snapshot.expand(["evan"]) == ["evan"]) // family gone from search too
    }
}

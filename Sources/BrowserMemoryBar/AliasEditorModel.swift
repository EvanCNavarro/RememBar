import Foundation

/// The `@MainActor` view-model behind the term-families editor. It holds the user's RAW draft — the
/// words exactly as typed, one `DraftRow` per family — which is deliberately NOT the sanitized model.
///
/// Why a separate draft: `AliasGroups.init` lowercases input and DELETES any group left with fewer
/// than two members. If the editor bound straight to `AliasGroups`, a family being built one word at
/// a time would vanish out from under the cursor and typed case would be "corrected." So the draft
/// preserves the user's rows/casing; edits are pushed THROUGH `AliasCatalog.update` (which sanitizes
/// for search + persists atomically) on every mutation — live apply, no Save button — but the draft
/// itself is never replaced by the sanitized result.
@MainActor
final class AliasEditorModel: ObservableObject {
    struct DraftRow: Identifiable, Equatable {
        let id: UUID
        var words: [String]
    }

    @Published private(set) var rows: [DraftRow]

    private let catalog: AliasCatalog

    init(catalog: AliasCatalog) {
        self.catalog = catalog
        self.rows = catalog.snapshot.families.map { DraftRow(id: UUID(), words: $0) }
    }

    /// A family is active (usable by search) once it has ≥2 members of ≥2 characters — mirrors
    /// `AliasGroups`' sanitization so the editor's hint matches what the engine will actually honor.
    func isActive(_ id: DraftRow.ID) -> Bool {
        guard let row = rows.first(where: { $0.id == id }) else { return false }
        let valid = Set(row.words.map { $0.lowercased() }.filter { $0.count > 1 })
        return valid.count >= 2
    }

    @discardableResult
    func addRow() -> DraftRow.ID {
        let row = DraftRow(id: UUID(), words: [])
        rows.append(row)
        // No commit — an empty row has nothing to persist and would just be dropped by sanitize.
        return row.id
    }

    func removeRow(_ id: DraftRow.ID) {
        rows.removeAll { $0.id == id }
        commit()
    }

    /// Append a word to a family. Trimmed; blanks ignored; de-duplicated case-insensitively within the
    /// row. Raw case is preserved in the draft (the engine lowercases on its own).
    func addWord(_ word: String, toRow id: DraftRow.ID) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let existing = Set(rows[index].words.map { $0.lowercased() })
        guard !existing.contains(trimmed.lowercased()) else { return }
        rows[index].words.append(trimmed)
        commit()
    }

    func removeWord(_ word: String, fromRow id: DraftRow.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].words.removeAll { $0.caseInsensitiveCompare(word) == .orderedSame }
        commit()
    }

    /// Push the current draft through the catalog: it sanitizes (drops <2-member/1-char), persists
    /// atomically, and publishes so the next search is live. The draft rows are intentionally left
    /// as-is so in-progress families keep their place.
    private func commit() {
        catalog.update(families: rows.map(\.words))
    }
}

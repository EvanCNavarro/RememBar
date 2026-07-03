import SwiftUI

/// The term-families editor: one row per family, each family a set of interchangeable-word chips plus
/// an add-word field. Live apply — every edit flows through `AliasEditorModel` → `AliasCatalog` and is
/// used by the very next search; there is no Save button (macOS settings are modeless). Restrained,
/// dark, native — sized for a small utility window, not a document editor.
struct AliasEditorView: View {
    @ObservedObject var model: AliasEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.space) {
            header
            Divider().overlay(Tokens.line)

            if model.rows.isEmpty {
                emptyState
            } else if isOffscreenRender {
                // ImageRenderer can't lay out lazy ScrollView content; render the identical rows in a
                // plain VStack for offscreen visual proof.
                familyRows.padding(.vertical, Tokens.micro)
            } else {
                ScrollView {
                    familyRows.padding(.vertical, Tokens.micro)
                }
            }

            addFamilyButton
        }
        .padding(Tokens.space + Tokens.micro)
        .frame(minWidth: 380, minHeight: 320)
        .background(Tokens.panel)
    }

    private var familyRows: some View {
        VStack(alignment: .leading, spacing: Tokens.space) {
            ForEach(model.rows) { row in
                FamilyRow(
                    row: row,
                    isActive: model.isActive(row.id),
                    onAddWord: { model.addWord($0, toRow: row.id) },
                    onRemoveWord: { model.removeWord($0, fromRow: row.id) },
                    onRemoveFamily: { model.removeRow(row.id) }
                )
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Term Families")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Tokens.text)
            Text("Group interchangeable words — searching any one also finds the others. Applies as you type.")
                .font(Tokens.caption)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Tokens.micro) {
            Spacer(minLength: Tokens.space)
            Text("No term families yet.")
                .font(Tokens.body)
                .foregroundStyle(Tokens.muted)
            Text("Add a family, then a few words that should mean the same thing (e.g. evan, ecn, navarro).")
                .font(Tokens.caption)
                .foregroundStyle(Tokens.quiet)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Tokens.space)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addFamily() { model.addRow() }

    private var addFamilyButton: some View {
        Button(action: addFamily) {
            HStack(spacing: Tokens.micro) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("Add Family")
                    .font(Tokens.caption.weight(.semibold))
            }
            .foregroundStyle(Tokens.text)
            .padding(.horizontal, Tokens.space)
            .frame(height: Tokens.controlButton)
            .background(
                RoundedRectangle(cornerRadius: Tokens.micro, style: .continuous)
                    .fill(Tokens.row)
                    .overlay(
                        RoundedRectangle(cornerRadius: Tokens.micro, style: .continuous)
                            .stroke(Tokens.line, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

/// One family row: its word chips, an add-word field, a remove-family control, and a quiet hint when
/// the family has fewer than two words (still inactive for search, but kept visible for editing).
private struct FamilyRow: View {
    let row: AliasEditorModel.DraftRow
    let isActive: Bool
    let onAddWord: (String) -> Void
    let onRemoveWord: (String) -> Void
    let onRemoveFamily: () -> Void

    @State private var draftWord = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.micro) {
            HStack(alignment: .top, spacing: Tokens.space) {
                ChipFlow(spacing: Tokens.micro) {
                    ForEach(row.words, id: \.self) { word in
                        WordChip(word: word, onRemove: { onRemoveWord(word) })
                    }
                    addWordField
                }
                Spacer(minLength: Tokens.micro)
                Button(action: onRemoveFamily) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tokens.quiet)
                        .frame(width: Tokens.controlButton, height: Tokens.controlButton)
                }
                .buttonStyle(.plain)
                .help("Remove this family")
                .accessibilityLabel("Remove family")
            }

            if !isActive {
                Text("Add another word to activate this family")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.quiet)
            }
        }
        .padding(Tokens.space)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous)
                .fill(Tokens.row)
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous)
                        .stroke(Tokens.line, lineWidth: 1)
                )
        )
    }

    private var addWordField: some View {
        TextField("add word", text: $draftWord)
            .textFieldStyle(.plain)
            .font(Tokens.caption)
            .foregroundStyle(Tokens.text)
            .frame(minWidth: 64)
            .onSubmit(commit)
            .onChange(of: draftWord) { _, new in
                // Comma commits too (Apple's default tokenizing character alongside Return).
                if new.contains(",") {
                    draftWord = new.replacingOccurrences(of: ",", with: "")
                    commit()
                }
            }
            .padding(.horizontal, Tokens.micro)
            .frame(height: 22)
    }

    private func commit() {
        onAddWord(draftWord)
        draftWord = ""
    }
}

/// A single word token with a remove affordance.
private struct WordChip: View {
    let word: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Tokens.micro) {
            Text(word)
                .font(Tokens.caption)
                .foregroundStyle(Tokens.text)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Tokens.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(word)")
        }
        .padding(.leading, Tokens.space)
        .padding(.trailing, Tokens.micro + 1)
        .frame(height: 22)
        .background(
            Capsule(style: .continuous)
                .fill(Tokens.rowActive)
                .overlay(Capsule(style: .continuous).stroke(Tokens.line, lineWidth: 1))
        )
    }
}

/// A minimal wrapping layout so chips flow onto new lines instead of clipping — pure SwiftUI
/// `Layout` (macOS 14), no AppKit token field.
private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var lineWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let advance = size.width + (rows[rows.count - 1].isEmpty ? 0 : spacing)
            if lineWidth + advance > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([size]); lineWidth = size.width
            } else {
                rows[rows.count - 1].append(size); lineWidth += advance
            }
        }
        let height = rows.reduce(0) { acc, line in
            acc + (line.map(\.height).max() ?? 0)
        } + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map { line in
            line.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, line.count - 1))
        }.max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var origin = CGPoint(x: bounds.minX, y: bounds.minY)
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x + size.width > bounds.minX + maxWidth, origin.x > bounds.minX {
                origin.x = bounds.minX
                origin.y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: origin, proposal: ProposedViewSize(size))
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

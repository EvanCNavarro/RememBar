import SwiftUI

/// The term-families editor: one card per family. Each card has a header line (the family's identity
/// + status + its delete control, kept together for proximity) over a chip row of its words plus a
/// clearly-affordanced "add word" target. Live apply — every edit flows through `AliasEditorModel` →
/// `AliasCatalog` and is used by the next search; there is no Save button (macOS settings are
/// modeless). Restrained, dark, native — sized for a small utility window.
struct AliasEditorView: View {
    @ObservedObject var model: AliasEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.space) {
            header
            Divider().overlay(Tokens.line)

            if model.rows.isEmpty {
                emptyState
                addFamilyButton
            } else if isOffscreenRender {
                // ImageRenderer can't lay out lazy ScrollView content; render the identical list in a
                // plain VStack for offscreen visual proof.
                familyList
            } else {
                ScrollView { familyList }
            }
        }
        .padding(Tokens.space + Tokens.micro)
        .frame(minWidth: 380, minHeight: 300)
        .background(Tokens.panel)
    }

    private var familyList: some View {
        VStack(alignment: .leading, spacing: Tokens.space) {
            ForEach(model.rows) { row in
                FamilyCard(
                    row: row,
                    isActive: model.isActive(row.id),
                    onAddWord: { model.addWord($0, toRow: row.id) },
                    onRemoveWord: { model.removeWord($0, fromRow: row.id) },
                    onRemoveFamily: { model.removeRow(row.id) }
                )
            }
            addFamilyButton
        }
        .padding(.vertical, Tokens.micro)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Term Families")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Tokens.text)
            Spacer(minLength: Tokens.space)
            Text("search any word, find the whole family")
                .font(Tokens.caption)
                .foregroundStyle(Tokens.quiet)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Tokens.micro) {
            Text("No term families yet.")
                .font(Tokens.body)
                .foregroundStyle(Tokens.muted)
            Text("Group words that should mean the same thing — e.g. evan, ecn, navarro — so searching "
                + "any one of them also surfaces the others.")
                .font(Tokens.caption)
                .foregroundStyle(Tokens.quiet)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Tokens.space)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addFamily() { model.addRow() }

    private var addFamilyButton: some View {
        Button(action: addFamily) {
            HStack(spacing: Tokens.micro) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("New family")
                    .font(Tokens.caption.weight(.semibold))
            }
            .foregroundStyle(Tokens.muted)
            .frame(maxWidth: .infinity)
            .frame(height: Tokens.control)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Tokens.lineStrong)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a new term family")
    }
}

/// One family card: a header line (identity + status + delete, grouped for proximity) over its word
/// chips and the add-word affordance.
private struct FamilyCard: View {
    let row: AliasEditorModel.DraftRow
    let isActive: Bool
    let onAddWord: (String) -> Void
    let onRemoveWord: (String) -> Void
    let onRemoveFamily: () -> Void

    // The family's scannable identity is its first word; a brand-new (wordless) family reads as such.
    private var identity: String { row.words.first ?? "New family" }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.space) {
            HStack(spacing: Tokens.micro + 2) {
                Text(identity)
                    .font(Tokens.caption.weight(.semibold))
                    .foregroundStyle(row.words.isEmpty ? Tokens.quiet : Tokens.text)
                    .lineLimit(1)
                if !isActive {
                    Text("· add a word to activate")
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.warning)
                        .lineLimit(1)
                }
                Spacer(minLength: Tokens.space)
                Button(action: onRemoveFamily) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Tokens.quiet)
                }
                .buttonStyle(.plain)
                .help("Remove this family")
                .accessibilityLabel("Remove \(identity) family")
            }

            ChipFlow(spacing: Tokens.micro) {
                ForEach(row.words, id: \.self) { word in
                    WordChip(word: word, onRemove: { onRemoveWord(word) })
                }
                AddWordField(onCommit: onAddWord)
            }
        }
        .padding(Tokens.space + Tokens.micro)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous)
                .fill(Tokens.row)
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous)
                        .stroke(Tokens.line, lineWidth: 1)
                )
        )
    }
}

/// The add-word affordance — a dashed "pill" that clearly reads as a target you type into, so it's
/// never mistaken for another chip. Commits on Return or comma.
private struct AddWordField: View {
    let onCommit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Tokens.micro) {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Tokens.quiet)
            TextField("word", text: $draft)
                .textFieldStyle(.plain)
                .font(Tokens.caption)
                .foregroundStyle(Tokens.text)
                .frame(minWidth: 40)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: draft) { _, new in
                    if new.contains(",") {
                        draft = new.replacingOccurrences(of: ",", with: "")
                        commit()
                    }
                }
        }
        .padding(.horizontal, Tokens.space)
        .frame(height: 24)
        .background(
            Capsule(style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(focused ? Tokens.lineStrong : Tokens.line)
        )
        .accessibilityLabel("Add a word to this family")
    }

    private func commit() {
        onCommit(draft)
        draft = ""
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
        .frame(height: 24)
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

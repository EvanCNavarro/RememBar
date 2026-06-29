import SwiftUI

struct QueryContext: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.micro) {
            Text(label)
                .font(Tokens.label)
                .foregroundStyle(Tokens.quiet)

            // The query in quotes, aligned with its label (no extra indent).
            Text("\u{201C}\(value)\u{201D}")
                .font(Tokens.caption)
                .foregroundStyle(Tokens.muted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
    }
}

struct LoadingRows: View {
    var body: some View {
        VStack(spacing: Tokens.space) {
            ForEach(0..<3, id: \.self) { _ in
                SkeletonBlock(cornerRadius: Tokens.radius)
                    .frame(height: 58)
            }
        }
        .accessibilityLabel("Loading results")
    }
}

struct ResultsList: View {
    @ObservedObject var store: MemorySearchStore

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.space) {
            HStack(spacing: Tokens.space) {
                Text("Results")
                    .font(Tokens.label)
                    .foregroundStyle(Tokens.quiet)
                Spacer(minLength: Tokens.space)
                SortToggle(mode: store.sortMode) { store.setSortMode(store.sortMode.next) }
            }

            VStack(spacing: Tokens.space) {
                ForEach(Array(store.results.enumerated()), id: \.element.id) { index, result in
                    let isSelected = store.selectedID == result.id
                    ResultLine(
                        result: result,
                        index: index,
                        isSelected: isSelected,
                        isDimmed: store.selectedID != nil && !isSelected,
                        select: { store.select(result) },
                        open: { store.open(result) }
                    )
                }
            }

            if store.totalPages > 1 {
                PaginationControls(store: store)
            }
        }
    }
}

/// Below the results: only the source problems worth acting on, each with its fix. Healthy
/// sources are silent — the panel is for results, not telemetry.
struct SourceExceptions: View {
    @ObservedObject var store: MemorySearchStore

    private var exceptions: [MemorySearchSourceStatus] {
        store.sourceStatuses.filter(\.isException)
    }

    var body: some View {
        if !exceptions.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.micro) {
                ForEach(exceptions) { status in
                    SourceExceptionRow(status: status) {
                        if let remediation = status.remediation {
                            store.performRemediation(remediation)
                        }
                    }
                }
            }
        }
    }
}

private struct SourceExceptionRow: View {
    let status: MemorySearchSourceStatus
    let action: () -> Void

    var body: some View {
        HStack(spacing: Tokens.space) {
            Image(systemName: status.systemImageName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.warning)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(status.sourceName)
                    .font(Tokens.caption.weight(.semibold))
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                Text(status.displayDetail)
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: Tokens.space)

            if let remediation = status.remediation {
                ActionPillButton(title: remediation.actionLabel, action: action)
                    .accessibilityLabel("\(remediation.actionLabel) for \(status.sourceName)")
            }
        }
        .padding(.horizontal, Tokens.space)
        .padding(.vertical, Tokens.micro + 2)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Tokens.warning.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Tokens.warning.opacity(0.4), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status.sourceName), \(status.stateLabel), \(status.accessibilityDetail)")
    }
}

/// A compact text+icon toggle (right of "Results") that cycles the sort order. Brightens + shows a
/// subtle background on hover, matching the panel's other controls.
private struct SortToggle: View {
    let mode: MemorySearchStore.SortMode
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.micro) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 9, weight: .semibold))
                Text(mode.label)
                    .font(Tokens.label)
            }
            .foregroundStyle(hovered ? Tokens.text : Tokens.muted)
            .padding(.horizontal, Tokens.micro + 2)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: Tokens.micro, style: .continuous)
                    .fill(hovered ? Tokens.row : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("Sort by \(mode.label). Activate to change.")
    }
}

private struct PaginationControls: View {
    @ObservedObject var store: MemorySearchStore

    var body: some View {
        HStack(spacing: Tokens.micro) {
            IconControlButton(action: store.goToPreviousPage) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
            }
            .disabled(!store.canGoToPreviousPage)
            .accessibilityLabel("Previous results page")

            Text(store.pageLabel)
                .font(Tokens.caption)
                .foregroundStyle(Tokens.muted)
                .frame(minWidth: 44)

            IconControlButton(action: store.goToNextPage) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .disabled(!store.canGoToNextPage)
            .accessibilityLabel("Next results page")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct ResultLine: View {
    let result: MemoryResult
    var index: Int = 0
    let isSelected: Bool
    let isDimmed: Bool
    let select: () -> Void
    let open: () -> Void
    @State private var shown = isOffscreenRender

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: select) {
                HStack(spacing: Tokens.space) {
                    ResultThumbnail(result: result)

                    VStack(alignment: .leading, spacing: Tokens.micro) {
                        Text(result.title)
                            .font(Tokens.body.weight(.semibold))
                            .foregroundStyle(Tokens.text)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(result.detail)
                            .font(Tokens.caption)
                            .foregroundStyle(Tokens.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if isSelected {
                        Color.clear.frame(width: 32, height: 40)
                    }
                }
                .frame(height: 40)
                .padding(Tokens.space)
                .contentShape(Rectangle())
            }
            .buttonStyle(ResultButtonStyle(isActive: isSelected))
            .accessibilityLabel("Select \(result.title)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if isSelected {
                VStack(alignment: .trailing, spacing: 2) {
                    DoubleCheckIcon()
                        .frame(width: 22, height: 18)

                    Button(action: open) {
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 22, height: 20)
                    }
                    .buttonStyle(IconButtonStyle(active: true, radius: Tokens.micro))
                    .help(result.target.actionLabel)
                    .accessibilityLabel("\(result.target.actionLabel) \(result.title)")
                }
                .frame(width: 32, height: 40, alignment: .trailing)
                .padding(.trailing, Tokens.space)
            }
        }
        .frame(height: 58)
        .opacity(shown ? (isDimmed ? 0.46 : 1) : 0)
        .offset(y: shown ? 0 : 6)
        .animation(.easeInOut(duration: 0.14), value: isDimmed)
        .animation(.easeInOut(duration: 0.14), value: isSelected)
        .onAppear {
            guard !shown else { return }
            // Soft, snappy stagger: each row springs up + fades in, offset by its position.
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82).delay(Double(index) * 0.045)) {
                shown = true
            }
        }
    }
}

private struct DoubleCheckIcon: View {
    var body: some View {
        ZStack {
            Image(systemName: "checkmark")
                .offset(x: -3)
            Image(systemName: "checkmark")
                .offset(x: 4)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Tokens.text)
    }
}

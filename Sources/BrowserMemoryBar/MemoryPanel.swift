import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct MemoryPanel: View {
    @ObservedObject var store: MemorySearchStore
    /// Sparkle is injected as an optional closure so this view (and the render harness) never
    /// import or instantiate the updater. The app passes `SparkleUpdater.shared.checkForUpdates`.
    var onCheckForUpdates: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.space) {
            HStack(spacing: Tokens.space) {
                CommandField(store: store)
                AboutControl(onCheckForUpdates: onCheckForUpdates)
            }

            if !store.baseQuery.isEmpty {
                QueryContext(label: store.phaseLabel, value: store.contextValue)
            }

            if store.isLoading {
                LoadingRows()
            }

            if !store.results.isEmpty {
                ResultsList(store: store)
            }

            // Source status sits BELOW results and shows only actionable problems — results are
            // the point of the panel, not telemetry about which browsers were searched.
            SourceExceptions(store: store)
        }
        .padding(Tokens.space)
        .background(Tokens.panel)
    }
}

private struct CommandField: View {
    @ObservedObject var store: MemorySearchStore
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Tokens.space) {
            RememBarGlyph(active: true)
                .frame(width: 20)
                .foregroundStyle(Tokens.muted)

            TextField(store.prompt, text: $store.inputText)
                .textFieldStyle(.plain)
                .font(Tokens.body)
                .foregroundStyle(Tokens.text)
                .disabled(store.isLoading)
                .focused($focused)
                .onSubmit(store.submit)
                .accessibilityLabel("Search files and browser history")

            if store.canClearSearch {
                IconControlButton(action: store.clearSearch) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .accessibilityLabel("Clear search and start over")
            }

            IconControlButton(action: store.submit) {
                ZStack {
                    Text("↵")
                        .font(.system(size: 15, weight: .medium))
                        .opacity(store.isLoading ? 0 : 1)

                    ProgressView()
                        .controlSize(.mini)
                        .opacity(store.isLoading ? 1 : 0)
                }
            }
            .disabled(store.isLoading)
            .accessibilityLabel(store.isLoading ? "Searching" : "Search")
        }
        .frame(height: Tokens.control)
        .padding(.leading, Tokens.space)
        .padding(.trailing, Tokens.micro)
        .background(Tokens.field)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous)
                .stroke(focused ? Tokens.lineStrong : Tokens.line, lineWidth: 1)
        }
        .onAppear {
            focused = true
        }
        .onChange(of: store.phase) {
            if !store.isLoading {
                focused = true
            }
        }
    }
}

/// The "?" control — not settings: an About panel answering what this is, who made it, and where
/// to learn more.
private struct AboutControl: View {
    var onCheckForUpdates: (() -> Void)? = nil
    @State private var showAbout = false

    var body: some View {
        IconControlButton(size: Tokens.control, radius: Tokens.radius, action: { showAbout.toggle() }) {
            Image(systemName: "questionmark")
                .font(.system(size: 14, weight: .semibold))
        }
        .accessibilityLabel("About RememBar")
        .popover(isPresented: $showAbout, arrowEdge: .bottom) {
            AboutPopover(onCheckForUpdates: onCheckForUpdates)
        }
    }
}

struct AboutPopover: View {
    /// Optional so the offscreen render harness stays Sparkle-free; the app injects the real check.
    var onCheckForUpdates: (() -> Void)? = nil

    private var versionLine: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.space) {
            // Header: icon (left, larger) + name / version / Check-for-Updates stacked to its right.
            HStack(alignment: .center, spacing: Tokens.space + Tokens.micro) {
                AppIconView()
                    .frame(width: 68, height: 68)

                VStack(alignment: .leading, spacing: 3) {
                    Text("RememBar")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Tokens.text)
                    Text(versionLine)
                        .font(Tokens.caption)
                        .foregroundStyle(Tokens.muted)
                    if let onCheckForUpdates {
                        CheckForUpdatesBar(action: onCheckForUpdates)
                            .padding(.top, Tokens.micro)
                    }
                }

                Spacer(minLength: 0)
            }

            Divider().overlay(Tokens.line)

            // What it does
            Text("A minimalistic menu-bar search for your system files, browser history, 1Password, etc.")
                .font(Tokens.caption)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)

            // Where to learn more
            LearnMoreLink(
                displayText: "ecn.dev/apps/RememBar",
                url: URL(string: "https://ecn.dev/apps/RememBar")!
            )

            // Quietest footer
            Text("© 2026 Evan C. Navarro")
                .font(Tokens.caption)
                .foregroundStyle(Tokens.quiet)
        }
        .padding(Tokens.space + Tokens.micro)
        .frame(width: 320, alignment: .leading)
        .background(Tokens.panel)
        // Match the system NSPopover's arrow to the panel color (see SolidPopoverChrome).
        .background(SolidPopoverChrome(color: Tokens.panel))
    }
}

/// The app's own icon (the real colorful AppIcon in the running app). Falls back to a brand tile
/// where no app icon is available (e.g. the offscreen render harness).
private struct AppIconView: View {
    var body: some View {
        if let icon = NSApplication.shared.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Tokens.field)
                .overlay(
                    Text("Rb")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Tokens.muted)
                )
        }
    }
}

/// Inline "Learn more at  <globe> link <↗>" — the link portion is clickable, brightens and
/// underlines on hover, and opens in the default browser.
private struct LearnMoreLink: View {
    let displayText: String
    let url: URL
    @State private var hovered = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: Tokens.micro + 1) {
                Text("Learn more:")
                    .foregroundStyle(Tokens.muted)
                Image(systemName: "globe")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Tokens.text)
                Text(displayText)
                    .fontWeight(.semibold)
                    .foregroundStyle(Tokens.text)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Tokens.text)
            }
            .font(Tokens.caption)
            .frame(maxWidth: .infinity)
            .frame(height: Tokens.controlButton + 4)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous)
                    .fill(hovered ? Tokens.rowActive : Tokens.row)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous)
                    .stroke(hovered ? Tokens.lineStrong : Tokens.line, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("Learn more at \(url.absoluteString)")
    }
}

/// A compact bordered "bar" button (sits under the version in the About header) that triggers a
/// Sparkle update check. Brightens on hover, matching the other About controls.
private struct CheckForUpdatesBar: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.micro + 1) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                Text("Check for Updates")
                    .font(Tokens.caption.weight(.medium))
            }
            .foregroundStyle(hovered ? Tokens.text : Tokens.muted)
            .padding(.horizontal, Tokens.space)
            .frame(height: Tokens.controlButton)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous)
                    .fill(hovered ? Tokens.rowActive : Tokens.row)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous)
                    .stroke(hovered ? Tokens.lineStrong : Tokens.line, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("Check for Updates")
    }
}

/// Walks up to the enclosing NSPopover's NSVisualEffectView and replaces its translucent material
/// with a solid color, so the popover (and its arrow) match the panel exactly.
private struct SolidPopoverChrome: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> NSView {
        let probe = NSView()
        DispatchQueue.main.async { [weak probe] in
            var ancestor = probe?.superview
            while let current = ancestor, !(current is NSVisualEffectView) {
                ancestor = current.superview
            }
            guard let effect = ancestor as? NSVisualEffectView else { return }
            effect.state = .inactive
            effect.material = .windowBackground
            effect.wantsLayer = true
            effect.layer?.backgroundColor = NSColor(color).cgColor
        }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct QueryContext: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.micro) {
            Text(label)
                .font(Tokens.label)
                .foregroundStyle(Tokens.quiet)

            Text(value)
                .font(Tokens.caption)
                .foregroundStyle(Tokens.muted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, Tokens.space)
        .accessibilityElement(children: .combine)
    }
}

private struct LoadingRows: View {
    var body: some View {
        VStack(spacing: Tokens.space) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous)
                    .fill(Tokens.row)
                    .overlay {
                        RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous)
                            .stroke(Tokens.line, lineWidth: 1)
                    }
                    .frame(height: 58)
                    .redacted(reason: .placeholder)
            }
        }
        .accessibilityLabel("Loading results")
    }
}

private struct ResultsList: View {
    @ObservedObject var store: MemorySearchStore

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.space) {
            Text("Results")
                .font(Tokens.label)
                .foregroundStyle(Tokens.quiet)

            VStack(spacing: Tokens.space) {
                ForEach(store.results) { result in
                    let isSelected = store.selectedID == result.id
                    ResultLine(
                        result: result,
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
private struct SourceExceptions: View {
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
    let isSelected: Bool
    let isDimmed: Bool
    let select: () -> Void
    let open: () -> Void

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
        .opacity(isDimmed ? 0.46 : 1)
        .animation(.easeInOut(duration: 0.14), value: isDimmed)
        .animation(.easeInOut(duration: 0.14), value: isSelected)
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

struct RememBarGlyph: View {
    let active: Bool
    var hidesFromAccessibility = true

    var body: some View {
        RememBarImage.menuGlyph
            .resizable()
            .scaledToFit()
            .foregroundStyle(active ? Tokens.text : Tokens.muted)
        .frame(width: 16, height: 16)
        .accessibilityHidden(hidesFromAccessibility)
    }
}

enum RememBarImage {
    private static let menuGlyphSize = NSSize(width: 18, height: 18)

    static var menuGlyph: Image {
        #if canImport(AppKit)
        if let image = nsMenuGlyph {
            return Image(nsImage: image).renderingMode(.template)
        }
        #endif
        return Image(systemName: "globe")
    }

    #if canImport(AppKit)
    static var nsMenuGlyph: NSImage? {
        guard let url = menuGlyphURL else {
            return nil
        }
        let image = NSImage(contentsOf: url)
        image?.size = menuGlyphSize
        image?.isTemplate = true
        return image
    }

    private static var menuGlyphURL: URL? {
        if let url = Bundle.main.url(forResource: "RememBarMenuGlyph", withExtension: "pdf") {
            return url
        }
        if let url = Bundle.module.url(forResource: "RememBarMenuGlyph", withExtension: "pdf") {
            return url
        }
        if let url = Bundle.main.url(forResource: "RememBarMenuGlyph", withExtension: "png") {
            return url
        }
        return Bundle.module.url(forResource: "RememBarMenuGlyph", withExtension: "png")
    }
    #endif
}

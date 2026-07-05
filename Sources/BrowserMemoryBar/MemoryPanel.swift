import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct MemoryPanel: View {
    @ObservedObject var store: MemorySearchStore
    /// Opens RememBar's settings window (Term Families, About, …). Injected so this view stays free of
    /// window/AppKit concerns; the app wires it to `SettingsWindowController`.
    var onOpenSettings: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.space) {
            HStack(spacing: Tokens.space) {
                CommandField(store: store)
                if let onOpenSettings {
                    // The single settings affordance — a gear that opens the tabbed settings window
                    // (Term Families, About). About moved out of a "?" popover into that window.
                    // 26pt (controlButton) like every other icon control + the ··· — was the lone 34pt
                    // outlier (audit #2). Radius stays Tokens.radius to match the ···.
                    IconControlButton(radius: Tokens.radius, action: onOpenSettings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .accessibilityLabel("Settings")
                }
            }

            if store.showsResultsQuery {
                QueryContext(label: store.phaseLabel, value: store.contextValue)
                    .transition(.opacity)
            }

            if store.isLoading {
                LoadingRows()
                    .transition(.opacity)
            }

            if !store.results.isEmpty {
                ResultsList(store: store)
                    // Instant in (the rows do their own staggered entrance); fade out on clear so the
                    // panel flushes gracefully instead of popping to empty.
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
                    // Dim the moment the rows stop matching the typed query, so they read as "stale /
                    // updating" — immediate feedback when you override a query, not a frozen list.
                    .opacity(store.resultsAreStale ? 0.45 : 1)
                    .animation(.easeInOut(duration: 0.15), value: store.resultsAreStale)
            }

            if store.showsNoResults {
                NoResultsRow(query: store.resultsQuery)
                    .transition(.opacity)
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

    /// A search is executing (a live re-search over existing results, or a cold search) — drive the
    /// bar's spinner off this so editing an already-searched query never looks frozen.
    private var searchInFlight: Bool { store.isSearching || store.isLoading }

    var body: some View {
        HStack(spacing: Tokens.space) {
            RememBarGlyph(active: true)
                .frame(width: 20)
                .foregroundStyle(Tokens.muted)

            TextField(store.prompt, text: $store.inputText)
                .textFieldStyle(.plain)
                .font(Tokens.body)
                .foregroundStyle(Tokens.text)
                // Never disabled: live search must stay typeable while a query is in flight.
                .focused($focused)
                .onChange(of: store.inputText) { store.inputChanged() }
                // Keyboard navigation of results while the field keeps focus: arrows move the
                // highlight (return .handled so the caret doesn't move), Enter opens the highlighted/
                // top result (or searches a stale query), Esc clears an active search.
                .onKeyPress(.upArrow) { store.moveSelectionUp(); return .handled }
                .onKeyPress(.downArrow) { store.moveSelectionDown(); return .handled }
                .onKeyPress(.escape) {
                    guard store.canClearSearch else { return .ignored }
                    withAnimation(.easeInOut(duration: 0.2)) { store.clearSearch() }
                    return .handled
                }
                .onSubmit(store.submitOrOpen)
                .accessibilityLabel("Search files and browser history")

            if store.canClearSearch {
                IconControlButton(
                    action: { withAnimation(.easeInOut(duration: 0.2)) { store.clearSearch() } }, content: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                    })
                .accessibilityLabel("Clear search and start over")
            }

            IconControlButton(action: store.submitOrOpen) {
                ZStack {
                    Text("↵")
                        .font(.system(size: 15, weight: .medium))
                        .opacity(searchInFlight ? 0 : 1)

                    ProgressView()
                        .controlSize(.mini)
                        .opacity(searchInFlight ? 1 : 0)
                }
            }
            .accessibilityLabel(searchInFlight ? "Searching" : "Search")
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
    // Cached: the bundled glyph never changes at runtime, so read + decode it once instead of on
    // every render (RememBarGlyph.body hits this each pass). nonisolated(unsafe) because RememBarImage
    // is a non-isolated enum and NSImage isn't Sendable; the image is built once here and only read
    // afterward (size/isTemplate are set before caching, never mutated later).
    nonisolated(unsafe) static let nsMenuGlyph: NSImage? = {
        guard let url = menuGlyphURL else {
            return nil
        }
        let image = NSImage(contentsOf: url)
        image?.size = menuGlyphSize
        image?.isTemplate = true
        return image
    }()

    private static var menuGlyphURL: URL? {
        Bundle.packagedResourceURL("RememBarMenuGlyph", withExtension: "pdf")
            ?? Bundle.packagedResourceURL("RememBarMenuGlyph", withExtension: "png")
    }
    #endif
}

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct MemoryPanel: View {
    @ObservedObject var store: MemorySearchStore
    /// Sparkle is injected as an optional closure so this view (and the render harness) never
    /// import or instantiate the updater. The app passes `SparkleUpdater.shared.checkForUpdates`.
    var onCheckForUpdates: (() -> Void)?
    /// Injected for the same reason — the app passes the real "move RememBar to the Trash" action.
    var onUninstall: (() -> Void)?
    /// Opens the Term Families editor window. Injected so this view stays free of window/AppKit concerns.
    var onManageFamilies: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.space) {
            HStack(spacing: Tokens.space) {
                CommandField(store: store)
                if let onManageFamilies {
                    // A distinct settings affordance — term families are configuration, not "help",
                    // so they get a gear next to the "?" rather than living inside the About menu.
                    IconControlButton(size: Tokens.control, radius: Tokens.radius, action: onManageFamilies) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .accessibilityLabel("Term Families")
                }
                AboutControl(onCheckForUpdates: onCheckForUpdates, onUninstall: onUninstall)
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
            }

            if store.showsNoResults {
                NoResultsRow()
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
                .onSubmit(store.submit)
                .accessibilityLabel("Search files and browser history")

            if store.canClearSearch {
                IconControlButton(
                    action: { withAnimation(.easeInOut(duration: 0.2)) { store.clearSearch() } }, content: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                    })
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

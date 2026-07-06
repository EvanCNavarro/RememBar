#if DEBUG
import AppKit
import MacFaceKit
import SwiftUI

/// Opens (and retains) the dev gallery window. Called from `RememBarApp.init()` via a main-queue
/// dispatch so `NSApp` is initialized by the time it runs.
@MainActor
enum GalleryWindowController {
    private static var window: NSWindow?

    static func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        NSApp.setActivationPolicy(.regular)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "RememBar — UI Gallery"
        // contentView (not contentViewController) so the window keeps its 1000x660 frame instead of
        // auto-resizing to a broken fitting size; the SwiftUI HStack fills the content bounds.
        win.contentView = NSHostingView(rootView: GalleryView())
        win.setContentSize(NSSize(width: 1000, height: 660))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }
}

/// A debug-only window that hosts the REAL production views (`MemoryPanel`, `AboutPopover`) so the
/// UI can be seen and clicked through without driving the live menu-bar app — and without any
/// hand-ported re-implementation. This is the literal SwiftUI, rendered by the real runtime
/// (the field types, the dropdown opens). Compiled out of release builds (`#if DEBUG`); launched
/// only when `REMEMBAR_GALLERY` is set (see `RememBarApp.body`). Sample data is clearly illustrative
/// — the *layout* is the real thing, the strings come straight from the views.
struct GalleryView: View {
    private enum Stage: String, CaseIterable, Identifiable {
        case empty = "Search — empty"
        case results = "Search — results"
        case loading = "Search — loading"
        case settings = "Settings — tabbed window"
        case updatePermission = "Update — permission"
        case updateAvailable = "Update — available"
        case updateChecking = "Update — checking"
        case updateProgress = "Update — downloading"
        case updateReady = "Update — ready to install"
        case updateUpToDate = "Update — up to date"
        case updateError = "Update — error"
        var id: String { rawValue }
    }

    private static let panelStages: [Stage] = [.empty, .results, .loading, .settings]
    // A live, in-memory catalog for the gallery settings window — scratch file, never the real config.
    @MainActor private static let gallerySettingsCatalog: AliasCatalog = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RememBarGalleryAliases", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let catalog = AliasCatalog(url: dir.appendingPathComponent("aliases.json"))
        catalog.update(families: [["evan", "ecn", "navarro"], ["mom", "mother"]])
        return catalog
    }()
    private static let updateStages: [Stage] = [.updatePermission, .updateAvailable, .updateChecking,
                                                .updateProgress, .updateReady, .updateUpToDate, .updateError]
    private static let sampleReleaseNotes = [
        "Term families (aliases) across files, history & password managers",
        "One-click \"Uninstall RememBar\" uninstaller",
        "Redesigned About panel + smoother result animations",
        "Custom in-app update flow (this dialog)",
        "Faster Spotlight indexing on large home folders",
        "Fixed Safari history reads under Full Disk Access",
        "Improved keyboard navigation and focus handling"
    ]

    // Defaults to the app's real default (.empty); REMEMBAR_GALLERY_STAGE=about|results|loading|... lets
    // a launch jump straight to a state for review without editing code.
    @State private var stage: Stage = {
        if let want = ProcessInfo.processInfo.environment["REMEMBAR_GALLERY_STAGE"]?.lowercased(),
           let match = Stage.allCases.first(where: { $0.rawValue.lowercased().contains(want) }) {
            return match
        }
        return .empty
    }()
    @State private var emptyStore = MemorySearchStore(
        searchProvider: GalleryFixedProvider(response: MemorySearchResponse(results: [], sourceStatuses: []))
    )
    @State private var resultsStore = MemorySearchStore(
        searchProvider: GalleryFixedProvider(response: GallerySampleData.response)
    )
    @State private var loadingStore = MemorySearchStore(searchProvider: GallerySlowProvider())
    @State private var notesExpanded = true

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            stagingArea
        }
        .frame(minWidth: 780, minHeight: 580)
        .onAppear {
            resultsStore.inputText = "linkedin"
            resultsStore.submit()
            loadingStore.inputText = "linkedin"
            loadingStore.submit()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("RememBar — UI Gallery")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.text)
                .padding(.bottom, 4)
            Text("Real SwiftUI, live & interactive")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.muted)
                .padding(.bottom, Tokens.space)

            sidebarGroup("Panel & About", Self.panelStages)
            sidebarGroup("Update flow", Self.updateStages)
            Spacer()
        }
        .padding(Tokens.space + Tokens.micro)
        .frame(width: 230)
        .background(Tokens.panel)
    }

    @ViewBuilder private func sidebarGroup(_ title: String, _ items: [Stage]) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Tokens.quiet)
            .padding(.horizontal, Tokens.space)
            .padding(.top, Tokens.space)
            .padding(.bottom, 2)
        ForEach(items) { item in
            Button { stage = item } label: {
                Text(item.rawValue)
                    .font(.system(size: 12))
                    .foregroundStyle(stage == item ? Tokens.text : Tokens.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Tokens.space)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.micro, style: .continuous)
                            .fill(stage == item ? Tokens.row : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var stagingArea: some View {
        ZStack {
            // A neutral desk-like backdrop so the panel reads as a floating menu-bar window.
            Color(red: 0.04, green: 0.042, blue: 0.05).ignoresSafeArea()
            stageView
                .padding(48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var stageView: some View {
        switch stage {
        case .empty:
            MemoryPanel(store: emptyStore).frame(width: 384)
        case .results:
            MemoryPanel(store: resultsStore).frame(width: 384)
        case .loading:
            MemoryPanel(store: loadingStore).frame(width: 384)
        case .settings:
            SettingsRootView(catalog: Self.gallerySettingsCatalog, onCheckForUpdates: {}, onUninstall: {})
                .frame(width: 480, height: 460)
        case .updatePermission:
            GalleryDialogFrame {
                UpdateDialog.permission(appName: RememBarPaths.appName, onAllow: {}, onDecline: {})
                    .icon(rememBarUpdateIcon)
            }
        case .updateAvailable:
            GalleryDialogFrame {
                UpdateDialog.available(appName: RememBarPaths.appName, version: "0.2.0", currentVersion: "0.1.0",
                                       notes: Self.sampleReleaseNotes, notesExpanded: $notesExpanded,
                                       onInstall: {}, onRemindLater: {}).icon(rememBarUpdateIcon)
            }
        case .updateChecking:
            GalleryDialogFrame { UpdateDialog.checking(onCancel: {}).icon(rememBarUpdateIcon) }
        case .updateProgress:
            GalleryDialogFrame {
                UpdateDialog.progress(appName: RememBarPaths.appName, heading: "Downloading update…",
                                      version: "0.2.0", fraction: 0.62, onCancel: {}).icon(rememBarUpdateIcon)
            }
        case .updateReady:
            GalleryDialogFrame {
                UpdateDialog.ready(appName: RememBarPaths.appName, version: "0.2.0", onRestart: {})
                    .icon(rememBarUpdateIcon)
            }
        case .updateUpToDate:
            GalleryDialogFrame {
                UpdateDialog.upToDate(appName: RememBarPaths.appName, version: "0.2.0", onOK: {})
                    .icon(rememBarUpdateIcon)
            }
        case .updateError:
            GalleryDialogFrame {
                UpdateDialog.error(message: "Couldn't reach the update server. Check your connection and try again.",
                                   onOK: {}).icon(rememBarUpdateIcon)
            }
        }
    }
}

/// Returns a fixed response immediately — for the empty and results states.
private struct GalleryFixedProvider: MemorySearching {
    let response: MemorySearchResponse
    func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse {
        response
    }
}

/// Never returns within a viewing session — holds the panel in its real `.loading` (skeleton) state.
private struct GallerySlowProvider: MemorySearching {
    func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse {
        try? await Task.sleep(for: .seconds(600))
        return MemorySearchResponse(results: [], sourceStatuses: [])
    }
}

/// Illustrative results so the populated state has something to lay out. The strings rendered around
/// them (labels, detail format) come from the real views/`MemoryResult`, not from here.
private enum GallerySampleData {
    static var response: MemorySearchResponse {
        let results: [MemoryResult] = [
            MemoryResult(fileURL: URL(fileURLWithPath: "/Users/example/Downloads/linkedin-export.csv"),
                         displayPath: "Downloads/linkedin-export.csv",
                         modifiedAt: Date(timeIntervalSince1970: 1_800_000_000), rank: 92),
            MemoryResult(fileURL: URL(fileURLWithPath: "/Users/example/Documents/LinkedIn cover letter.md"),
                         displayPath: "Documents/LinkedIn cover letter.md",
                         modifiedAt: Date(timeIntervalSince1970: 1_790_000_000), rank: 74),
            MemoryResult(fileURL: URL(fileURLWithPath: "/Users/example/Pictures/linkedin-headshot.png"),
                         displayPath: "Pictures/linkedin-headshot.png",
                         modifiedAt: Date(timeIntervalSince1970: 1_780_000_000), rank: 60)
        ]
        let statuses: [MemorySearchSourceStatus] = [
            MemorySearchSourceStatus(id: "safari", sourceName: "Safari", state: .blocked,
                                     detail: "Permission required"),
            MemorySearchSourceStatus(id: MemorySearchSourceStatus.onePasswordID, sourceName: "1Password",
                                     state: .blocked, detail: "Unlock or sign in to 1Password"),
            MemorySearchSourceStatus(id: "chrome", sourceName: "Chrome", state: .searched, detail: "522 visits")
        ]
        return MemorySearchResponse(results: results, sourceStatuses: statuses)
    }
}

/// A plain rounded card that mocks the dialog window in the gallery (the real driver uses a system
/// window). No title bar — the header line carries the state.
struct GalleryDialogFrame<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .fixedSize()
            .background(Tokens.updateWindow)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.black.opacity(0.45), lineWidth: 1))
    }
}
#endif

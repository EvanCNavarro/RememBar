import Foundation

/// The single authority for RememBar's identity and on-disk footprint.
///
/// Every path the app *owns* — its Application Support folder, preferences, caches, saved state —
/// is derived here from the app's identity (name + the bundle ids it has ever shipped under), never
/// hard-coded and never duplicated. The diagnostics directory, the alias config, and the uninstaller
/// all read from this one type so they cannot drift. `bundleIDs` carries prior ids on purpose: the
/// app shipped as `com.evancnavarro.remembar` before the rename, and that residue must still be
/// findable. Paths are folder-granular (the whole `Application Support/RememBar` directory), so new
/// files added under it later need no change here.
struct RememBarPaths {
    static let appName = "RememBar"
    /// Current id first, then every prior id — so the footprint covers leftovers from renames.
    static let bundleIDs = ["dev.ecn.apps.remembar", "com.evancnavarro.remembar"]

    /// Canonical outbound links (identity constants) — the single Swift-side source the About card reads,
    /// so they're never hard-coded in a view. `HEAD` (not a branch) so a rename never 404s the license.
    static let repoURL = URL(string: "https://github.com/EvanCNavarro/RememBar")!
    static let licenseURL = URL(string: "https://github.com/EvanCNavarro/RememBar/blob/HEAD/LICENSE")!

    /// `~/Library` — injected so the footprint is unit-testable against a sandbox home.
    let library: URL
    /// The running `.app` bundle, self-located via `Bundle.main`. `nil` under tests / CLI.
    let bundleURL: URL?

    init(library: URL, bundleURL: URL?) {
        self.library = library
        self.bundleURL = bundleURL
    }

    /// The live authority: real `~/Library`, and the bundle this code is running inside.
    static var current: RememBarPaths {
        RememBarPaths(
            library: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true),
            bundleURL: Bundle.main.bundleURL
        )
    }

    private var applicationSupport: URL {
        library.appendingPathComponent("Application Support", isDirectory: true)
    }

    /// `~/Library/Application Support/RememBar` — the app's own data root.
    var supportDirectory: URL {
        applicationSupport.appendingPathComponent(Self.appName, isDirectory: true)
    }

    /// Where the diagnostics log + session state live (a subfolder of the data root).
    var diagnosticsDirectory: URL {
        supportDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    /// The user-curated alias-group config (0.2.0+), beside the data root. Managed in-app via the Term
    /// Families editor (`AliasCatalog`), which writes it atomically and applies edits to the next
    /// search live; an external hand-edit still applies on the next launch (or catalog `reload()`).
    var aliasesURL: URL {
        supportDirectory.appendingPathComponent("aliases.json", isDirectory: false)
    }

    /// Every data path RememBar owns — trashable while the app is still running. Folder-granular:
    /// `supportDirectory` covers Diagnostics + aliases + anything future in one entry. The running
    /// `.app` bundle is deliberately NOT here — it can't delete itself live, so the uninstaller
    /// hands it to a detached helper.
    var dataPaths: [URL] {
        var paths = [supportDirectory]
        for id in Self.bundleIDs {
            paths.append(library.appendingPathComponent("Preferences/\(id).plist", isDirectory: false))
            paths.append(library.appendingPathComponent("Caches/\(id)", isDirectory: true))
            paths.append(library.appendingPathComponent("Saved Application State/\(id).savedState", isDirectory: true))
        }
        return paths
    }
}

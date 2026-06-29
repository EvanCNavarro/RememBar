import Foundation

/// Removes RememBar from the Mac — its data and its app bundle — moving everything to the Trash
/// (recoverable, never `rm`). It touches ONLY the paths declared by `RememBarPaths`; there is no
/// glob, prefix-match, or wildcard, so a neighbour like `…/Application Support/RememBarOther` is
/// never caught. The trash operation is injectable purely so the safety tests can prove the scope
/// without writing to the real Trash.
struct RememBarUninstaller {
    private let paths: RememBarPaths
    private let fileManager: FileManager
    private let trash: (URL) throws -> Void

    init(
        paths: RememBarPaths = .current,
        fileManager: FileManager = .default,
        trash: ((URL) throws -> Void)? = nil
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.trash = trash ?? { url in
            var resultingURL: NSURL?
            try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
        }
    }

    /// Moves every owned data path that exists (support dir, prefs/caches/state for all known ids)
    /// to the Trash. Best-effort per path; returns the paths actually removed.
    @discardableResult
    func removeData() -> [URL] {
        var removed: [URL] = []
        for url in paths.dataPaths where fileManager.fileExists(atPath: url.path) {
            if (try? trash(url)) != nil {
                removed.append(url)
            }
        }
        return removed
    }

    /// Moves the running `.app` bundle to the Trash. macOS allows trashing a running app (a
    /// same-volume move). Throws if it can't (e.g. the bundle lives somewhere the user can't write)
    /// so the caller can fall back to asking the user to drag it to the Trash by hand.
    func removeBundle() throws {
        guard let bundleURL = paths.bundleURL, fileManager.fileExists(atPath: bundleURL.path) else { return }
        try trash(bundleURL)
    }
}

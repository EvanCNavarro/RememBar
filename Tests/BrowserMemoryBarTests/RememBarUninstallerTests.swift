@testable import BrowserMemoryBar
import Foundation
import Testing

@Suite("RememBar Uninstaller")
struct RememBarUninstallerTests {
    private func sandbox() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("remembar-uninstall-test", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Materialise a path on disk: prefs are files, everything else is a directory (with a nested
    /// file, to prove the removal is folder-granular).
    private func create(_ url: URL, fileManager fm: FileManager) throws {
        if url.pathExtension == "plist" {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url.appendingPathComponent("inner.txt"))
        }
    }

    @Test("removeData trashes every owned path but NOTHING else (decoy safety)")
    func decoySafety() throws {
        let fm = FileManager.default
        let root = sandbox()
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let paths = RememBarPaths(library: library, bundleURL: nil)

        for url in paths.dataPaths { try create(url, fileManager: fm) }

        // Deliberately adjacent / similar-prefix neighbours that a glob or prefix-match would catch.
        let decoys = [
            library.appendingPathComponent("Application Support/RememBarOther", isDirectory: true),
            library.appendingPathComponent("Application Support/RememBar Backup", isDirectory: true),
            library.appendingPathComponent("Preferences/dev.ecn.apps.remembar.helper.plist", isDirectory: false),
            library.appendingPathComponent("Preferences/com.other.app.plist", isDirectory: false)
        ]
        for decoy in decoys { try create(decoy, fileManager: fm) }

        var trashed: [String] = []
        let sut = RememBarUninstaller(paths: paths, fileManager: fm, trash: { url in
            trashed.append(url.path)
            try fm.removeItem(at: url) // simulate the Trash by removing from the sandbox
        })
        let removed = sut.removeData()

        for url in paths.dataPaths {
            #expect(!fm.fileExists(atPath: url.path), "owned path survived: \(url.path)")
        }
        for decoy in decoys {
            #expect(fm.fileExists(atPath: decoy.path), "decoy was wrongly removed: \(decoy.path)")
        }
        // Scoping invariant: nothing outside dataPaths is ever handed to trash.
        let owned = Set(paths.dataPaths.map(\.path))
        #expect(trashed.allSatisfy { owned.contains($0) })
        #expect(Set(removed.map(\.path)).isSubset(of: owned))

        try? fm.removeItem(at: root)
    }

    @Test("removeData is idempotent — second run removes nothing, no error")
    func idempotent() throws {
        let fm = FileManager.default
        let root = sandbox()
        let paths = RememBarPaths(library: root.appendingPathComponent("Library", isDirectory: true), bundleURL: nil)
        try fm.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)

        let sut = RememBarUninstaller(paths: paths, fileManager: fm, trash: { try fm.removeItem(at: $0) })
        #expect(!sut.removeData().isEmpty) // first run removes the support dir
        #expect(sut.removeData().isEmpty) // second run: nothing left, no throw

        try? fm.removeItem(at: root)
    }

    @Test("removeBundle trashes the located bundle; no-op when absent")
    func bundleRemoval() throws {
        let fm = FileManager.default
        let root = sandbox()
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let bundle = root.appendingPathComponent("RememBar.app", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)

        var trashed: [String] = []
        try RememBarUninstaller(paths: RememBarPaths(library: library, bundleURL: bundle), fileManager: fm, trash: {
            trashed.append($0.path)
            try fm.removeItem(at: $0)
        }).removeBundle()
        #expect(trashed == [bundle.path])

        // Absent bundle: no throw, nothing trashed.
        try RememBarUninstaller(paths: RememBarPaths(library: library, bundleURL: nil), fileManager: fm, trash: { _ in
            Issue.record("should not trash when there is no bundle")
        }).removeBundle()

        try? fm.removeItem(at: root)
    }
}

@testable import BrowserMemoryBar
import Foundation
import Testing

@Suite("RememBar Paths")
struct RememBarPathsTests {
    private func paths(bundleURL: URL? = nil) -> (RememBarPaths, URL) {
        let library = URL(fileURLWithPath: "/tmp/remembar-test-home", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
        return (RememBarPaths(library: library, bundleURL: bundleURL), library)
    }

    @Test("data root + derived dirs match the conventional layout")
    func derivedDirectories() {
        let (sut, library) = paths()
        let support = library.appendingPathComponent("Application Support/RememBar", isDirectory: true)
        #expect(sut.supportDirectory == support)
        #expect(sut.diagnosticsDirectory == support.appendingPathComponent("Diagnostics", isDirectory: true))
        #expect(sut.aliasesURL == support.appendingPathComponent("aliases.json", isDirectory: false))
    }

    @Test("dataPaths is exactly the owned set — support root + prefs/caches/state for every known id")
    func dataPathsExactSet() {
        let (sut, library) = paths()
        var expected: Set<String> = [
            library.appendingPathComponent("Application Support/RememBar", isDirectory: true).path
        ]
        for id in RememBarPaths.bundleIDs {
            expected.insert(library.appendingPathComponent("Preferences/\(id).plist").path)
            expected.insert(library.appendingPathComponent("Caches/\(id)", isDirectory: true).path)
            expected.insert(library.appendingPathComponent("Saved Application State/\(id).savedState", isDirectory: true).path)
        }
        #expect(Set(sut.dataPaths.map(\.path)) == expected)
    }

    @Test("covers the renamed bundle id (residue from before the rename)")
    func includesPriorBundleID() {
        let (sut, _) = paths()
        let all = sut.dataPaths.map(\.path).joined(separator: "\n")
        #expect(all.contains("dev.ecn.apps.remembar")) // current
        #expect(all.contains("com.evancnavarro.remembar")) // prior — must not be orphaned
    }

    @Test("the running bundle is NOT in dataPaths — it needs the detached helper, not a live trash")
    func bundleExcludedFromDataPaths() {
        let bundle = URL(fileURLWithPath: "/Applications/RememBar.app", isDirectory: true)
        let (sut, _) = paths(bundleURL: bundle)
        #expect(!sut.dataPaths.contains(bundle))
        #expect(sut.bundleURL == bundle)
    }
}

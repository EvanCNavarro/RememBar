import Foundation

extension Bundle {
    /// Locate a bundled resource the way a *shipped* RememBar.app must: from the main app bundle
    /// (`Contents/Resources`), never from `Bundle.module` in a release build.
    ///
    /// `Bundle.module`'s SwiftPM-generated accessor `fatalError`s when it can't find the resource
    /// bundle — and it looks in exactly two places: inside the .app (which the hand-rolled packaging
    /// does not place there) and a *hardcoded absolute `.build` path baked in at compile time*. In a
    /// CI-built release that path is the CI checkout (`/Users/runner/...`), which exists on no user's
    /// machine, so any `Bundle.module` access crashes the app on launch. A locally-built binary only
    /// appears to work because its baked-in path happens to resolve on the build machine.
    ///
    /// So: release resolves resources solely via `Bundle.main` (they must be packaged into
    /// `Contents/Resources`); the `Bundle.module` fallback is compiled in for DEBUG only, where
    /// `swift run`/tests have no app bundle and the build path is valid.
    static func packagedResourceURL(_ name: String, withExtension ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }
        #if DEBUG
        return Bundle.module.url(forResource: name, withExtension: ext)
        #else
        return nil
        #endif
    }
}

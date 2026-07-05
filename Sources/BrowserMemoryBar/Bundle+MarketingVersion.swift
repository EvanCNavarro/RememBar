import Foundation

extension Bundle {
    /// `CFBundleShortVersionString` — the marketing version, or `nil` if the key is absent. The single
    /// reader of the key literal in RememBar so a typo can't silently diverge across call sites (#29-B5).
    /// The identity/About display reads its version via `MacFaceKit.AppInfo`; this serves the two
    /// non-identity sites (telemetry, update UI) that keep their OWN fallbacks (a nil-able telemetry
    /// field; the "this version" phrase) — so their distinct semantics are preserved, not consolidated.
    var marketingVersion: String? {
        infoDictionary?["CFBundleShortVersionString"] as? String
    }
}

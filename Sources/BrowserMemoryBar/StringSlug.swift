import Foundation

extension String {
    /// A stable, URL/ID-safe slug: every run of non-alphanumeric characters collapses to a single
    /// hyphen. Used to build source identifiers from browser/profile/location names.
    func slugified() -> String {
        components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}

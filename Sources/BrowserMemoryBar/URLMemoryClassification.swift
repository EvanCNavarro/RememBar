import Foundation

extension URL {
    var normalizedHost: String {
        host()?.lowercased().removingWWW() ?? ""
    }

    var isYouTubeURL: Bool {
        normalizedHost == "youtu.be" || normalizedHost == "youtube.com" || normalizedHost.hasSuffix(".youtube.com")
    }
}

private extension String {
    func removingWWW() -> String {
        hasPrefix("www.") ? String(dropFirst(4)) : self
    }
}

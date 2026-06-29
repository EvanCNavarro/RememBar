import Foundation

enum MemorySearchTokenizer {
    static func tokenize(_ text: String) -> [String] {
        let folded = text.lowercased()
            .replacingOccurrences(of: #"(?<=[a-z0-9])['’](?=[a-z0-9])"#, with: "", options: .regularExpression)
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
    }
}

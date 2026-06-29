import Foundation

struct SpotlightFileQueryPlan: Equatable, Sendable {
    let searchTerms: [String]
    let entityTerms: [String]
    let descriptorTerms: [String]
    let allowedExtensions: [String]
    let query: String
    let hasExplicitFileIntent: Bool

    init(query: String, refinements: [String]) {
        let tokens = MemorySearchTokenizer.tokenize(([query] + refinements).joined(separator: " "))
        hasExplicitFileIntent = tokens.contains(where: Self.isFileIntentTerm)
        let extensionHints = Self.extensionHints(for: tokens)
        let ignored = Self.ignoredTerms
            .union(Self.fileTypeTerms)
            .union(Self.explicitFileExtensions)
        searchTerms = tokens.filter { !ignored.contains($0) }.uniquePreservingOrder()
        descriptorTerms = searchTerms.filter(Self.isDescriptorTerm)
        entityTerms = searchTerms.filter { !Self.isDescriptorTerm($0) }
        allowedExtensions = extensionHints
        self.query = Self.buildQuery(
            entityTerms: entityTerms,
            descriptorTerms: descriptorTerms,
            allowedExtensions: allowedExtensions
        )
    }

    static func escapeLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static let ignoredTerms: Set<String> = [
        "and", "for", "from", "the", "that", "this", "with", "file", "files",
        "document", "documents", "doc", "docs", "finder", "local", "open", "show",
        "find", "search"
    ]

    private static let searchableDescriptorVocabulary: Set<String> = [
        "card", "cards", "soccer", "football", "sport", "sports",
        "template", "templates", "copy", "copies", "design", "designs",
        "photo", "photos", "picture", "pictures", "image", "images",
        "avatar", "avatars", "edit", "edited", "edits"
    ]

    private static let contextDescriptorVocabulary: Set<String> = [
        "gold", "golden", "keep", "number", "numbers", "rating", "ratings",
        "score", "scores", "stat", "stats", "total"
    ]

    private static let fileAccessIntentVocabulary: Set<String> = [
        "file", "files", "folder", "folders", "finder",
        "document", "documents", "asset", "assets", "media"
    ]

    private static let fileTypeTerms: Set<String> = ["adobe", "photoshop"]

    private static func extensionHints(for tokens: [String]) -> [String] {
        let explicitExtensions = tokens.filter { Self.explicitFileExtensions.contains($0) }.uniquePreservingOrder()
        if !explicitExtensions.isEmpty {
            return explicitExtensions
        }
        guard tokens.contains(where: { Self.broadPhotoshopTerms.contains($0) }) else { return [] }
        return Self.photoshopExtensions
    }

    private static let broadPhotoshopTerms: Set<String> = ["adobe", "photoshop"]
    private static let photoshopExtensions = ["psd", "psb", "psdt"]
    private static let imageExtensions = ["png", "jpg", "jpeg", "heic", "gif", "webp", "tif", "tiff"]
    private static let explicitFileExtensions = Set(photoshopExtensions + imageExtensions)

    private static func isDescriptorTerm(_ term: String) -> Bool {
        searchableDescriptorVocabulary.contains(term) ||
            contextDescriptorVocabulary.contains(term) ||
            term.allSatisfy(\.isNumber)
    }

    private static func isFileIntentTerm(_ term: String) -> Bool {
        fileAccessIntentVocabulary.contains(term) ||
            fileTypeTerms.contains(term) ||
            explicitFileExtensions.contains(term)
    }

    private static func buildQuery(
        entityTerms: [String],
        descriptorTerms: [String],
        allowedExtensions: [String]
    ) -> String {
        let candidateTerms = candidateTerms(entityTerms: entityTerms, descriptorTerms: descriptorTerms)
        let termPredicates = candidateTerms.map { term in
            let literal = escapeLiteral(term)
            return #"(kMDItemFSName == "*\#(literal)*"cd || kMDItemDisplayName == "*\#(literal)*"cd)"#
        }
        let extensionPredicates = allowedExtensions.map { ext in
            #"kMDItemFSName == "*.\#(escapeLiteral(ext))"cd"#
        }

        switch (termPredicates.isEmpty, extensionPredicates.isEmpty) {
        case (false, false):
            return "(\(termPredicates.joined(separator: " || "))) && (\(extensionPredicates.joined(separator: " || ")))"
        case (false, true):
            return termPredicates.joined(separator: " || ")
        case (true, false):
            return extensionPredicates.joined(separator: " || ")
        case (true, true):
            return ""
        }
    }

    private static func candidateTerms(entityTerms: [String], descriptorTerms: [String]) -> [String] {
        let searchableDescriptors = descriptorTerms.filter { searchableDescriptorVocabulary.contains($0) }
        let identityBackedTerms = (entityTerms + searchableDescriptors).uniquePreservingOrder()
        if !identityBackedTerms.isEmpty {
            return identityBackedTerms
        }
        return descriptorTerms.uniquePreservingOrder()
    }
}

private extension Array where Element == String {
    func uniquePreservingOrder() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}

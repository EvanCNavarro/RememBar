import Foundation

/// How Sparkle labeled a set of embedded release notes (`SUAppcastItem.itemDescriptionFormat`).
enum ReleaseNotesFormat: Equatable {
    case markdown
    case plainText
    case html

    /// Map Sparkle's format string. A nil or unrecognized value defaults to HTML, matching Sparkle's
    /// own fallback for legacy appcasts (see `SUAppcastItem`), so old feeds keep working.
    init(sparkleFormat raw: String?) {
        switch raw?.lowercased() {
        case "markdown": self = .markdown
        case "plain-text", "plaintext", "text": self = .plainText
        default: self = .html
        }
    }
}

/// The single place that turns appcast release-notes markup into the flat `[String]` of bullet items
/// the update dialog's "What's new" section renders. Sparkle delivers notes two ways — embedded on the
/// appcast item (`itemDescription`, as markdown / plain-text / html) or downloaded from a
/// `releaseNotesLink` (HTML) — and both funnel through here so the list is produced identically.
///
/// The contract is a *flat bullet list* (RememBar authors its notes that way): one item per line, with
/// leading bullet glyphs and the common inline emphasis markers stripped. It is deliberately not a full
/// markdown renderer — nested structure and headers are out of scope by design.
enum ReleaseNotesParser {
    /// Bullet items from raw markup, or `nil` when nothing renderable remains.
    static func items(from markup: String, format: ReleaseNotesFormat) -> [String]? {
        let plain: String
        switch format {
        case .html:
            plain = htmlToPlainText(markup) ?? markup
        case .markdown, .plainText:
            plain = markup
        }

        let leadingBullets = CharacterSet(charactersIn: "•*-–—\u{2022} \t")
        let items = plain
            .components(separatedBy: .newlines)
            .map { line in
                stripInlineEmphasis(line)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: leadingBullets)
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
        return items.isEmpty ? nil : items
    }

    /// Convenience for downloaded release notes, which Sparkle always delivers as HTML data.
    static func items(from data: Data, format: ReleaseNotesFormat = .html) -> [String]? {
        guard !data.isEmpty, let markup = String(data: data, encoding: .utf8) else { return nil }
        return items(from: markup, format: format)
    }

    /// Flatten HTML to its visible text. Uses `NSAttributedString`'s HTML importer, so call on the main
    /// thread (the driver already does). Returns nil if the importer can't parse the markup.
    private static func htmlToPlainText(_ html: String) -> String? {
        guard let data = html.data(using: .utf8) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        return try? NSAttributedString(data: data, options: options, documentAttributes: nil).string
    }

    /// Drop the common inline markdown emphasis markers so `**New:** …` reads as `New: …`.
    private static func stripInlineEmphasis(_ line: String) -> String {
        var out = line
        for marker in ["**", "__", "`"] {
            out = out.replacingOccurrences(of: marker, with: "")
        }
        return out
    }
}

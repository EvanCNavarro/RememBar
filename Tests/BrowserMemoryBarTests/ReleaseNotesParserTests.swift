@testable import BrowserMemoryBar
import Foundation
import Testing

/// The update dialog's "What's new" list is only as good as the parser that feeds it. Sparkle hands us
/// release notes in three shapes — embedded markdown, embedded plain-text, or downloaded HTML — and
/// every one has to collapse to the same flat `[String]` of bullet items. These pin that contract.
struct ReleaseNotesParserTests {
    // MARK: Format mapping (Sparkle's itemDescriptionFormat string)

    @Test func mapsSparkleFormatStrings() {
        #expect(ReleaseNotesFormat(sparkleFormat: "markdown") == .markdown)
        #expect(ReleaseNotesFormat(sparkleFormat: "plain-text") == .plainText)
        #expect(ReleaseNotesFormat(sparkleFormat: "html") == .html)
    }

    @Test func defaultsUnknownOrMissingFormatToHTML() {
        // Sparkle treats a nil/legacy format as HTML; we match it so old appcasts don't break.
        #expect(ReleaseNotesFormat(sparkleFormat: nil) == .html)
        #expect(ReleaseNotesFormat(sparkleFormat: "rtf") == .html)
    }

    // MARK: Markdown (the embedded path generate_appcast --embed-release-notes produces)

    @Test func parsesMarkdownBulletList() {
        let markdown = """
        - First improvement
        - Second improvement
        - Third improvement
        """
        #expect(ReleaseNotesParser.items(from: markdown, format: .markdown)
            == ["First improvement", "Second improvement", "Third improvement"])
    }

    @Test func stripsAssortedBulletGlyphsAndInlineEmphasis() {
        let markdown = """
        * Star bullet with **bold** text
        • Unicode bullet with `code`
        - Dash bullet with __underline__
        """
        #expect(ReleaseNotesParser.items(from: markdown, format: .markdown)
            == ["Star bullet with bold text", "Unicode bullet with code", "Dash bullet with underline"])
    }

    @Test func dropsBlankLinesBetweenBullets() {
        let markdown = "- One\n\n- Two\n   \n- Three"
        #expect(ReleaseNotesParser.items(from: markdown, format: .markdown) == ["One", "Two", "Three"])
    }

    // MARK: Plain text

    @Test func parsesPlainTextLines() {
        #expect(ReleaseNotesParser.items(from: "One\nTwo", format: .plainText) == ["One", "Two"])
    }

    // MARK: HTML (the downloaded releaseNotesLink path)

    @MainActor @Test func parsesHTMLListIntoItems() {
        let html = "<ul><li>Alpha change</li><li>Beta change</li></ul>"
        #expect(ReleaseNotesParser.items(from: html, format: .html) == ["Alpha change", "Beta change"])
    }

    @MainActor @Test func parsesHTMLFromRawData() {
        let data = Data("<ul><li>From data</li></ul>".utf8)
        #expect(ReleaseNotesParser.items(from: data) == ["From data"])
    }

    // MARK: Empty / nothing renderable

    @Test func returnsNilForEmptyOrWhitespaceMarkup() {
        #expect(ReleaseNotesParser.items(from: "", format: .markdown) == nil)
        #expect(ReleaseNotesParser.items(from: "   \n  \n", format: .plainText) == nil)
    }

    @Test func returnsNilForEmptyData() {
        #expect(ReleaseNotesParser.items(from: Data()) == nil)
    }
}

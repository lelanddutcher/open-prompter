//
//  MarkdownCleanerTests.swift
//  OpenPrompterTests
//

import XCTest
@testable import OpenPrompter

final class MarkdownCleanerTests: XCTestCase {

    func loadFixture(_ name: String) throws -> String {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "md", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "md") else {
            XCTFail("Missing fixture: \(name)")
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Frontmatter

    func testStripsYAMLFrontmatter() throws {
        let raw = try loadFixture("script-with-frontmatter")
        let parsed = MarkdownCleaner.clean(text: raw)
        XCTAssertFalse(parsed.bodyText.contains("author:"),
                       "Frontmatter key should be stripped")
        XCTAssertFalse(parsed.bodyText.contains("2026-04-22"),
                       "Frontmatter date should be stripped")
        XCTAssertTrue(parsed.bodyText.contains("first spoken paragraph"))
        XCTAssertTrue(parsed.bodyText.contains("second paragraph"))
    }

    func testFrontmatterProducesMultipleParagraphs() throws {
        let raw = try loadFixture("script-with-frontmatter")
        let parsed = MarkdownCleaner.clean(text: raw)
        XCTAssertGreaterThanOrEqual(parsed.paragraphs.count, 2)
    }

    // MARK: - AI-generated callouts

    func testStripsAICallouts() throws {
        let raw = try loadFixture("script-with-ai-callout")
        let parsed = MarkdownCleaner.clean(text: raw)
        XCTAssertFalse(parsed.bodyText.lowercased().contains("ai-generated"))
        XCTAssertFalse(parsed.bodyText.contains("[!"))
        XCTAssertTrue(parsed.bodyText.contains("visible paragraph"))
        XCTAssertTrue(parsed.bodyText.contains("final visible paragraph"))
    }

    // MARK: - Visual directions

    func testStripsBRollAndScreenRecordBrackets() throws {
        let raw = try loadFixture("script-with-broll")
        let parsed = MarkdownCleaner.clean(text: raw)
        // Check for the bracketed cue payload rather than bare substrings —
        // words like "B-Roll" legitimately appear in the section heading.
        XCTAssertFalse(parsed.bodyText.lowercased().contains("wide shot of the rig"))
        XCTAssertFalse(parsed.bodyText.lowercased().contains("showing the app"))
        XCTAssertFalse(parsed.bodyText.lowercased().contains("[insert"))
        XCTAssertFalse(parsed.bodyText.lowercased().contains("[text on screen"))
        XCTAssertFalse(parsed.bodyText.lowercased().contains("[b-roll"))
        XCTAssertTrue(parsed.bodyText.contains("first spoken line"))
        XCTAssertTrue(parsed.bodyText.contains("second spoken line"))
    }

    // MARK: - Footnote + reference section dropping

    func testDropsFootnoteSection() throws {
        let raw = try loadFixture("script-with-broll")
        let parsed = MarkdownCleaner.clean(text: raw)
        XCTAssertFalse(parsed.bodyText.contains("this footnote block should be dropped"),
                       "Footnotes section should be removed entirely")
    }

    func testDropsReferenceImagesSection() throws {
        let raw = try loadFixture("script-with-broll")
        let parsed = MarkdownCleaner.clean(text: raw)
        XCTAssertFalse(parsed.bodyText.lowercased().contains("reference images"))
        XCTAssertFalse(parsed.bodyText.contains("| Shot |"))
    }

    // MARK: - Empty input

    func testEmptyInputReturnsEmptyParsedScript() {
        XCTAssertTrue(MarkdownCleaner.clean(text: "").isEmpty)
    }

    func testWhitespaceOnlyInputReturnsEmptyParsedScript() {
        XCTAssertTrue(MarkdownCleaner.clean(text: "   \n\n   \t  \n").isEmpty)
    }

    // MARK: - Word count

    func testWordCountMatchesBody() {
        // "hello world." (2) + "here is another line." (4) = 6 whitespace-separated tokens.
        let parsed = MarkdownCleaner.clean(text: "hello world.\n\nhere is another line.")
        XCTAssertEqual(parsed.wordCount, 6)
    }

    // MARK: - Wikilinks (Obsidian-specific)

    func testWikilinksResolveToDisplayText() throws {
        let raw = try loadFixture("script-with-wikilinks")
        let parsed = MarkdownCleaner.clean(text: raw)
        XCTAssertFalse(parsed.bodyText.contains("[["),
                       "Wikilink brackets must be stripped")
        XCTAssertFalse(parsed.bodyText.contains("]]"))
        XCTAssertTrue(parsed.bodyText.contains("the app"),
                      "Piped wikilink should resolve to alias")
        XCTAssertTrue(parsed.bodyText.contains("Note"),
                      "Plain wikilink should resolve to target text")
    }

    // MARK: - Regular blockquote preservation

    func testRegularBlockquotePreserved() throws {
        let raw = try loadFixture("script-with-regular-blockquote")
        let parsed = MarkdownCleaner.clean(text: raw)
        XCTAssertTrue(
            parsed.bodyText.contains("real quoted speech"),
            "A non-AI blockquote should survive the parser."
        )
        XCTAssertTrue(parsed.bodyText.contains("intro paragraph"))
        XCTAssertTrue(parsed.bodyText.contains("closing paragraph"))
    }

    // MARK: - Multi-paragraph AI callout

    func testMultiParagraphAICalloutFullyStripped() throws {
        let raw = try loadFixture("script-with-multi-paragraph-callout")
        let parsed = MarkdownCleaner.clean(text: raw)
        XCTAssertFalse(parsed.bodyText.contains("first AI paragraph"))
        XCTAssertFalse(parsed.bodyText.contains("second AI paragraph"))
        XCTAssertFalse(parsed.bodyText.contains("third AI paragraph"))
        XCTAssertFalse(parsed.bodyText.lowercased().contains("ai-generated"))
        XCTAssertTrue(parsed.bodyText.contains("spoken opener"))
        XCTAssertTrue(parsed.bodyText.contains("also spoken"))
    }

    // MARK: - Code fences

    func testFencedCodeBlockStripped() throws {
        let raw = try loadFixture("script-with-code-fence")
        let parsed = MarkdownCleaner.clean(text: raw)
        XCTAssertFalse(parsed.bodyText.contains("let x = 1"))
        XCTAssertFalse(parsed.bodyText.contains("print(x)"))
        XCTAssertTrue(parsed.bodyText.contains("before the code"))
        XCTAssertTrue(parsed.bodyText.contains("after the code"))
    }

    // MARK: - Wikilinks helper (direct)

    func testStripWikilinksDirectly() {
        XCTAssertEqual(
            MarkdownCleaner.stripWikilinks("[[Page]]"),
            "Page"
        )
        XCTAssertEqual(
            MarkdownCleaner.stripWikilinks("[[Page|alias]]"),
            "alias"
        )
        XCTAssertEqual(
            MarkdownCleaner.stripWikilinks("before [[A]] and [[B|c]] after"),
            "before A and c after"
        )
    }
}

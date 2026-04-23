//
//  DemoMarkdownTests.swift
//  OpenPrompterTests
//
//  Runs the parser against the bundled demo-everything.md and asserts that
//  every "should strip" construct is gone and every "should keep" construct
//  survives. This is the all-in-one parser regression test.
//

import XCTest
@testable import OpenPrompter

final class DemoMarkdownTests: XCTestCase {

    private var parsed: ParsedScript!

    override func setUpWithError() throws {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "demo-everything", withExtension: "md", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "demo-everything", withExtension: "md") else {
            XCTFail("Missing demo-everything.md fixture")
            throw CocoaError(.fileNoSuchFile)
        }
        let raw = try String(contentsOf: url, encoding: .utf8)
        self.parsed = MarkdownCleaner.clean(text: raw)
    }

    // MARK: - Should-Strip Assertions

    func testFrontmatterStripped() {
        XCTAssertFalse(parsed.bodyText.contains("open-prompter"))
        XCTAssertFalse(parsed.bodyText.contains("everything-markdown"))
        XCTAssertFalse(parsed.bodyText.contains("author:"))
    }

    func testAICalloutFullyStripped() {
        let body = parsed.bodyText.lowercased()
        // The marker itself — not the raw words "ai-generated" which
        // legitimately appear in the "### 2. ai-generated callouts" heading.
        XCTAssertFalse(body.contains("[!ai-generated]"),
                       "AI callout marker leaked into spoken text")
        XCTAssertFalse(body.contains("this entire callout block"),
                       "First AI callout paragraph leaked")
        XCTAssertFalse(body.contains("second paragraph still inside"),
                       "Second AI callout paragraph leaked")
        XCTAssertFalse(body.contains("third paragraph, same story"),
                       "Third AI callout paragraph leaked")
    }

    func testVisualDirectionsStripped() {
        let body = parsed.bodyText.lowercased()
        XCTAssertFalse(body.contains("b-roll"))
        XCTAssertFalse(body.contains("screen record"))
        XCTAssertFalse(body.contains("text on screen"))
        XCTAssertFalse(body.contains("[insert"))
        XCTAssertFalse(body.contains("cut to"))
        XCTAssertFalse(body.contains("archival footage"))
        XCTAssertFalse(body.contains("close-up of the phone"))
    }

    func testFootnotesStripped() {
        XCTAssertFalse(parsed.bodyText.contains("[^1]"))
        XCTAssertFalse(parsed.bodyText.contains("[^sources]"))
        XCTAssertFalse(parsed.bodyText.contains("never be spoken aloud"))
        XCTAssertFalse(parsed.bodyText.contains("still dropped"))
    }

    func testScaffoldHeadingsStripped() {
        let body = parsed.bodyText.lowercased()
        XCTAssertFalse(body.contains("hook type"))
        XCTAssertFalse(body.contains("pillar"))
        XCTAssertFalse(body.contains("template"))
    }

    func testFootnotesSectionDropped() {
        // The dedicated "## Footnotes" section should not contribute any text.
        let body = parsed.bodyText.lowercased()
        XCTAssertFalse(body.contains("any content here is invisible"))
    }

    func testReferenceImagesSectionDropped() {
        let body = parsed.bodyText.lowercased()
        XCTAssertFalse(body.contains("clipsweeper.com/screenshot"))
        XCTAssertFalse(body.contains("openprompter.app/preview"))
    }

    func testTopicWaterfallSectionDropped() {
        let body = parsed.bodyText.lowercased()
        XCTAssertFalse(body.contains("also dropped by pattern match"))
    }

    func testTablesStripped() {
        XCTAssertFalse(parsed.bodyText.contains("| shot |"))
        XCTAssertFalse(parsed.bodyText.contains("| --- |"))
    }

    func testCodeBlocksStripped() {
        XCTAssertFalse(parsed.bodyText.contains("let x = 1"))
        XCTAssertFalse(parsed.bodyText.contains("print(x)"))
    }

    func testHTMLBlocksStripped() {
        XCTAssertFalse(parsed.bodyText.contains("<div>"))
        XCTAssertFalse(parsed.bodyText.contains("</div>"))
    }

    func testMarkdownMarkersStripped() {
        // Emphasis markers removed, content kept.
        XCTAssertFalse(parsed.bodyText.contains("**Bold"))
        XCTAssertFalse(parsed.bodyText.contains("*Italic"))
        // Backticks from inline code removed.
        XCTAssertFalse(parsed.bodyText.contains("`code spans`"))
        XCTAssertFalse(parsed.bodyText.contains("`inline code`"))
    }

    func testWikilinkBracketsStripped() {
        XCTAssertFalse(parsed.bodyText.contains("[["))
        XCTAssertFalse(parsed.bodyText.contains("]]"))
    }

    // MARK: - Should-Keep Assertions

    func testHeroParagraphKept() {
        XCTAssertTrue(parsed.bodyText.contains("If you can read this sentence cleanly"))
    }

    func testWhyThisExistsKept() {
        XCTAssertTrue(parsed.bodyText.contains("Every teleprompter app on the App Store"))
    }

    func testWikilinkDisplayTextKept() {
        XCTAssertTrue(parsed.bodyText.contains("the storage tool"),
                      "Piped wikilink should resolve to alias")
    }

    func testBoldTextSurvives() {
        XCTAssertTrue(parsed.bodyText.contains("Bold text stays bold"))
    }

    func testItalicTextSurvives() {
        XCTAssertTrue(parsed.bodyText.contains("Italic also survives"))
    }

    func testInlineCodeWordKept() {
        XCTAssertTrue(parsed.bodyText.contains("MIT licensed"))
        XCTAssertTrue(parsed.bodyText.contains("code spans"))
    }

    func testRegularBlockquoteSurvives() {
        XCTAssertTrue(parsed.bodyText.contains("real quoted line"),
                      "Non-AI blockquote should survive")
    }

    func testNonAICalloutTextSurvives() {
        // [!note] and [!quote] markers stripped, text preserved.
        XCTAssertTrue(parsed.bodyText.contains("This is a note callout"))
        XCTAssertTrue(parsed.bodyText.contains("The right teleprompter is the one"))
    }

    func testListItemsKept() {
        // List markers dropped but items flow into spoken text.
        XCTAssertTrue(parsed.bodyText.contains("Free forever"))
        XCTAssertTrue(parsed.bodyText.contains("MIT licensed"))
        XCTAssertTrue(parsed.bodyText.contains("Pick your folder once"))
    }

    func testEmojiAndUnicodePreserved() {
        XCTAssertTrue(parsed.bodyText.contains("📱"))
    }

    func testCloseParagraphKept() {
        XCTAssertTrue(parsed.bodyText.contains("If you made it this far"))
    }

    // MARK: - Structure

    func testMultipleParagraphsEmitted() {
        XCTAssertGreaterThanOrEqual(parsed.paragraphs.count, 10,
                                    "Demo script should produce multiple spoken paragraphs")
    }

    func testWordCountIsReasonable() {
        // Demo script should produce at least 200 words of spoken content
        // after stripping. If this drops much below, the parser is too aggressive.
        XCTAssertGreaterThan(parsed.wordCount, 200)
    }
}

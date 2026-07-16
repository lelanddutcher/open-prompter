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

    // MARK: - Stage-direction / camera-cue display formatting (V3 item 4)

    func testStripsInlineBracketCueAndSmoothsFlow() {
        let raw = "Welcome back. [Cut to: close-up] Today we talk about lenses."
        let parsed = MarkdownCleaner.clean(text: raw, rules: .aggressive)
        XCTAssertFalse(parsed.bodyText.contains("["))
        XCTAssertFalse(parsed.bodyText.lowercased().contains("cut to"))
        XCTAssertTrue(parsed.bodyText.contains("Welcome back."))
        XCTAssertTrue(parsed.bodyText.contains("Today we talk about lenses."))
        // Flow smooths: no double space left where the cue was removed.
        XCTAssertFalse(parsed.bodyText.contains("  "),
                       "Removing a mid-sentence cue must collapse the gap")
        XCTAssertTrue(parsed.bodyText.contains("Welcome back. Today"),
                      "Surrounding flow should read continuously")
    }

    func testStripsParentheticalBeat() {
        let raw = "I paused. (beat) Then I continued."
        let parsed = MarkdownCleaner.clean(text: raw, rules: .aggressive)
        XCTAssertFalse(parsed.bodyText.contains("(beat)"))
        XCTAssertTrue(parsed.bodyText.contains("I paused."))
        XCTAssertTrue(parsed.bodyText.contains("Then I continued."))
        XCTAssertFalse(parsed.bodyText.contains("  "))
    }

    func testStripsInlineAllCapsShotDirection() {
        let raw = "We open on the host. WIDE SHOT of the studio. Then closer."
        let parsed = MarkdownCleaner.clean(text: raw, rules: .aggressive)
        XCTAssertFalse(parsed.bodyText.contains("WIDE SHOT"))
        XCTAssertTrue(parsed.bodyText.contains("We open on the host."))
        XCTAssertTrue(parsed.bodyText.contains("Then closer."))
    }

    func testDropsWholeLineStageDirectionBlocks() {
        let raw = """
        First spoken paragraph.

        CUT TO: the anchor desk

        Second spoken paragraph.

        (beat)

        [B-roll: the rig on a tripod]

        Third spoken paragraph.
        """
        let parsed = MarkdownCleaner.clean(text: raw, rules: .aggressive)
        XCTAssertTrue(parsed.bodyText.contains("First spoken paragraph."))
        XCTAssertTrue(parsed.bodyText.contains("Second spoken paragraph."))
        XCTAssertTrue(parsed.bodyText.contains("Third spoken paragraph."))
        XCTAssertFalse(parsed.bodyText.lowercased().contains("anchor desk"))
        XCTAssertFalse(parsed.bodyText.contains("(beat)"))
        XCTAssertFalse(parsed.bodyText.lowercased().contains("b-roll"))
        XCTAssertFalse(parsed.bodyText.contains("["))
    }

    func testStageDirectionStrippingPreservesOrdinaryParentheticalsAndCaps() {
        let raw = "The price (about $30) is fair. I said NO to upsells."
        let parsed = MarkdownCleaner.clean(text: raw, rules: .aggressive)
        XCTAssertTrue(parsed.bodyText.contains("(about $30)"),
                      "Ordinary parenthetical asides must survive")
        XCTAssertTrue(parsed.bodyText.contains("NO"),
                      "Emphatic caps must survive")
    }

    func testGentleModeKeepsStageDirectionsVisible() {
        let raw = "Welcome. [Cut to: desk] (beat) I continue. WIDE SHOT here."
        let parsed = MarkdownCleaner.clean(text: raw, rules: .gentle)
        XCTAssertTrue(parsed.bodyText.contains("[Cut to: desk]"),
                      "Gentle mode keeps bracket cues visible on camera")
        XCTAssertTrue(parsed.bodyText.contains("(beat)"),
                      "Gentle mode keeps parentheticals visible")
        XCTAssertTrue(parsed.bodyText.contains("WIDE SHOT"),
                      "Gentle mode keeps ALL-CAPS shot directions visible")
    }

    func testAggressiveKeepingStageDirectionsKeepsBroadCuesButStripsLegacy() {
        // With aggressive stripping ON but the stage-direction toggle OFF, the
        // legacy `[B-roll: …]` bracket still strips (it's in `visualDirection`),
        // but `(beat)` and ALL-CAPS shot directions survive.
        let raw = "Intro. [B-roll: the rig] (beat) middle. WIDE SHOT here. Outro."
        let parsed = MarkdownCleaner.clean(
            text: raw,
            rules: .aggressiveKeepingStageDirections
        )
        XCTAssertFalse(parsed.bodyText.lowercased().contains("b-roll"),
                       "Legacy visual-direction bracket still strips")
        XCTAssertTrue(parsed.bodyText.contains("(beat)"),
                      "Broadened parenthetical cue survives when the toggle is off")
        XCTAssertTrue(parsed.bodyText.contains("WIDE SHOT"),
                      "Broadened caps cue survives when the toggle is off")
    }

    // MARK: - Source-untouched (display-time-only contract)

    func testSourceStringUntouchedByStageDirectionStripping() {
        // The cleaner must NEVER mutate the caller's source string. It emits a
        // separate render copy (`ParsedScript`). This pins the display-time-
        // only contract for the stage-direction feature.
        let original = """
        Welcome back. [Cut to: close-up] (beat) Today we talk about lenses.

        CUT TO: the anchor desk

        WIDE SHOT of the studio. That is all.
        """
        let snapshot = original
        _ = MarkdownCleaner.clean(text: original, rules: .aggressive)
        XCTAssertEqual(
            original, snapshot,
            "clean() must not mutate the source string — display-time only"
        )
        // The cues are all still present in the untouched source.
        XCTAssertTrue(original.contains("[Cut to: close-up]"))
        XCTAssertTrue(original.contains("(beat)"))
        XCTAssertTrue(original.contains("CUT TO: the anchor desk"))
        XCTAssertTrue(original.contains("WIDE SHOT of the studio."))
    }

    func testPlainProjectionStaysConsistentAfterCueRemoval() {
        // Voice tracking / word count / edit-teleport all read `bodyText`. The
        // per-block plain projection and the styled runs must agree, so the
        // flattened body has no stray markers after cue removal.
        let raw = "Line **one** here. [Cut to: desk] Line *two* there."
        let parsed = MarkdownCleaner.clean(text: raw, rules: .aggressive)
        XCTAssertFalse(parsed.bodyText.contains("["))
        XCTAssertFalse(parsed.bodyText.contains("*"),
                       "Emphasis markers are never in the plain projection")
        XCTAssertTrue(parsed.bodyText.contains("Line one here."))
        XCTAssertTrue(parsed.bodyText.contains("Line two there."))
        // Word count reflects only spoken words (cue words are gone).
        XCTAssertFalse(parsed.bodyText.lowercased().contains("cut to"))
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

//
//  EmphasisRenderingTests.swift
//  OpenPrompterTests
//
//  Regression coverage for GitHub #3 ("emphasis not rendered"). The parser
//  must preserve bold / italic / inline-code as styled `InlineRun`s on each
//  block WITHOUT changing the plain-text projection that voice tracking, word
//  count, and edit-teleport depend on. These assert at the value level (no
//  SwiftUI), so they pin the data contract the renderer reads.
//

import XCTest
@testable import OpenPrompter

final class EmphasisRenderingTests: XCTestCase {

    /// The styled text of the first `.paragraph` block in the parsed output.
    private func firstParagraph(_ markdown: String) -> StyledText? {
        let parsed = MarkdownCleaner.clean(text: markdown)
        for block in parsed.blocks {
            if case .paragraph(let styled) = block { return styled }
        }
        return nil
    }

    /// The run that contains a given substring, if any.
    private func run(containing needle: String, in styled: StyledText?) -> InlineRun? {
        styled?.runs.first { $0.text.contains(needle) }
    }

    // MARK: - Emphasis is preserved as runs

    func testBoldRunIsMarkedBold() {
        let styled = firstParagraph("This is **bold** text.")
        XCTAssertEqual(styled?.plain, "This is bold text.")
        let bold = run(containing: "bold", in: styled)
        XCTAssertEqual(bold?.bold, true)
        XCTAssertEqual(bold?.italic, false)
    }

    func testItalicRunIsMarkedItalic() {
        let styled = firstParagraph("This is *italic* here.")
        let italic = run(containing: "italic", in: styled)
        XCTAssertEqual(italic?.italic, true)
        XCTAssertEqual(italic?.bold, false)
    }

    func testTripleEmphasisIsBoldAndItalic() {
        let styled = firstParagraph("Look ***here*** now.")
        let both = run(containing: "here", in: styled)
        XCTAssertEqual(both?.bold, true)
        XCTAssertEqual(both?.italic, true)
    }

    func testInlineCodeRunIsFlaggedCode() {
        let styled = firstParagraph("Run `swift build` to compile.")
        let code = run(containing: "swift build", in: styled)
        XCTAssertEqual(code?.code, true)
        // Backticks are gone from the displayed text.
        XCTAssertEqual(styled?.plain.contains("`"), false)
    }

    func testSurroundingTextStaysUnstyled() {
        let styled = firstParagraph("plain **bold** plain")
        let leading = styled?.runs.first
        XCTAssertEqual(leading?.bold, false)
        XCTAssertEqual(leading?.italic, false)
        XCTAssertEqual(leading?.text, "plain ")
    }

    // MARK: - Plain text is unchanged (markers stripped)

    func testPlainParagraphIsASingleUnstyledRun() {
        let styled = firstParagraph("Just plain words here.")
        XCTAssertEqual(styled?.runs.count, 1)
        XCTAssertEqual(styled?.runs.first?.bold, false)
        XCTAssertEqual(styled?.runs.first?.italic, false)
        XCTAssertEqual(styled?.runs.first?.code, false)
    }

    func testRunsJoinExactlyToPlain() {
        let styled = firstParagraph("Mix of **bold**, *italic*, and `code` words.")
        XCTAssertEqual(styled?.runs.map(\.text).joined(), styled?.plain)
    }

    func testBodyTextStillStripsMarkers() {
        let parsed = MarkdownCleaner.clean(text: "A **bold** and *italic* line.")
        XCTAssertFalse(parsed.bodyText.contains("**"))
        XCTAssertFalse(parsed.bodyText.contains("*"))
        XCTAssertTrue(parsed.bodyText.contains("bold"))
        XCTAssertTrue(parsed.bodyText.contains("italic"))
    }

    func testWhitespaceCollapsesAroundEmphasis() {
        // Source line wraps / double spaces collapse to one, even at the seams
        // between a styled run and the text around it.
        let styled = firstParagraph("one   **two**   three")
        XCTAssertEqual(styled?.plain, "one two three")
    }

    // MARK: - Lists carry emphasis

    func testBulletKeepsEmphasis() {
        let parsed = MarkdownCleaner.clean(text: "- a **bold** bullet")
        var found = false
        for block in parsed.blocks {
            if case .bullet(let styled) = block {
                XCTAssertEqual(styled.plain, "a bold bullet")
                XCTAssertEqual(styled.runs.first { $0.text.contains("bold") }?.bold, true)
                found = true
            }
        }
        XCTAssertTrue(found, "Expected a bullet block")
    }

    // MARK: - Cleanup still wins over emphasis

    func testBracketCueStrippedButEmphasisSurvivesAfter() {
        // A visual-direction cue on its own line is removed; the spoken
        // sentence after it keeps its emphasis and never shows the cue.
        let parsed = MarkdownCleaner.clean(text: "[B-roll: wide shot]\n\nThe **real** line.")
        XCTAssertFalse(parsed.bodyText.lowercased().contains("b-roll"))
        var sawBold = false
        for block in parsed.blocks {
            if case .paragraph(let styled) = block {
                for r in styled.runs {
                    XCTAssertFalse(r.text.lowercased().contains("b-roll"))
                    if r.text.contains("real") {
                        XCTAssertTrue(r.bold)
                        sawBold = true
                    }
                }
            }
        }
        XCTAssertTrue(sawBold, "Bold emphasis should survive on the spoken line")
    }
}

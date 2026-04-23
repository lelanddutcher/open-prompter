//
//  StrippingRulesTests.swift
//  OpenPrompterTests
//

import XCTest
@testable import OpenPrompter

final class StrippingRulesTests: XCTestCase {

    // MARK: - Aggressive mode

    func testAggressiveStripsFrontmatter() {
        let rules = StrippingRules.aggressive
        let input = """
        ---
        author: claude
        tags:
          - test
        ---

        hello world
        """
        let result = rules.frontmatter.removingMatches(in: input)
        XCTAssertFalse(result.contains("author:"))
        XCTAssertFalse(result.contains("tags:"))
        XCTAssertTrue(result.contains("hello world"))
    }

    func testAggressiveStripsAICallout() {
        let rules = StrippingRules.aggressive
        let input = """
        visible.

        > [!ai-generated]
        > ignore this block

        also visible.
        """
        let result = rules.aiCallout.removingMatches(in: input)
        XCTAssertFalse(result.lowercased().contains("ai-generated"))
        XCTAssertFalse(result.contains("ignore this block"))
        XCTAssertTrue(result.contains("visible."))
        XCTAssertTrue(result.contains("also visible."))
    }

    func testAggressiveStripsFootnoteDef() {
        let rules = StrippingRules.aggressive
        let input = """
        [^1]: this is a footnote definition

        not a footnote.
        """
        let result = rules.footnoteDef.removingMatches(in: input)
        XCTAssertFalse(result.contains("footnote definition"))
        XCTAssertTrue(result.contains("not a footnote"))
    }

    func testAggressiveStripsFootnoteMarker() {
        let rules = StrippingRules.aggressive
        let input = "This sentence has a footnote[^1] in it[^nota-bene]."
        let result = rules.footnoteMarker.removingMatches(in: input)
        XCTAssertFalse(result.contains("[^"))
        XCTAssertTrue(result.contains("This sentence has a footnote"))
        XCTAssertTrue(result.contains(" in it"))
    }

    func testAggressiveStripsVisualDirections() {
        let rules = StrippingRules.aggressive
        let samples = [
            "[B-roll: hand picking up a camera]",
            "[b roll: wide shot]",
            "[Screen record: the app in dark mode]",
            "[insert archival footage]",
            "[Text on screen: \"mirror is free\"]",
            "[Cut to: close-up of the phone]"
        ]
        for sample in samples {
            let body = "before. \(sample) after."
            let result = rules.visualDirection.removingMatches(in: body)
            XCTAssertFalse(
                result.lowercased().contains("b-roll")
                || result.lowercased().contains("screen record")
                || result.lowercased().contains("[insert")
                || result.lowercased().contains("text on screen")
                || result.lowercased().contains("cut to"),
                "Should have stripped: \(sample). Got: \(result)"
            )
        }
    }

    func testScaffoldLabelDetectsStandardHeadings() {
        let rules = StrippingRules.aggressive
        let labels = [
            "Hook Type:",
            "Pillar",
            "Template:",
            "Version A",
            "Version B",
            "Footnotes",
            "Reference Images",
            "Topic Waterfall",
            "Related",
            "Sources"
        ]
        for label in labels {
            XCTAssertTrue(
                rules.scaffoldLabel.hasMatch(in: label),
                "Should match scaffold label: \(label)"
            )
        }
    }

    func testScaffoldLabelIgnoresRegularHeadings() {
        let rules = StrippingRules.aggressive
        let realHeadings = [
            "this is not a scaffold label",
            "What I Use",
            "The Big Take",
            "CFexpress cards are expensive"
        ]
        for heading in realHeadings {
            XCTAssertFalse(
                rules.scaffoldLabel.hasMatch(in: heading),
                "Should NOT match real heading: \(heading)"
            )
        }
    }

    // MARK: - Gentle mode

    func testGentleKeepsVisualDirections() {
        let rules = StrippingRules.gentle
        let input = "before. [B-roll: wide shot] after."
        let result = rules.visualDirection.removingMatches(in: input)
        XCTAssertEqual(
            result, input,
            "Gentle mode should not strip visual directions."
        )
    }

    func testGentleStillStripsFrontmatter() {
        let rules = StrippingRules.gentle
        let input = "---\nauthor: x\n---\n\nhello"
        let result = rules.frontmatter.removingMatches(in: input)
        XCTAssertFalse(result.contains("author:"))
    }
}

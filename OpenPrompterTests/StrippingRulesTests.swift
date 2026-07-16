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

    // MARK: - Stage-direction / camera-cue detection (V3 item 4)

    func testAggressiveEnablesStageDirectionStripping() {
        XCTAssertTrue(StrippingRules.aggressive.stripStageDirections)
    }

    func testGentleDisablesStageDirectionStripping() {
        XCTAssertFalse(StrippingRules.gentle.stripStageDirections)
    }

    func testAggressiveKeepingStageDirectionsFlagOff() {
        XCTAssertFalse(StrippingRules.aggressiveKeepingStageDirections.stripStageDirections)
    }

    func testResolvedSelectsCorrectRuleSet() {
        // aggressive off -> gentle regardless of the stage-direction toggle
        XCTAssertFalse(
            StrippingRules.resolved(aggressive: false, stripStageDirections: true).stripStageDirections
        )
        XCTAssertFalse(
            StrippingRules.resolved(aggressive: false, stripStageDirections: false).stripStageDirections
        )
        // aggressive on -> stage-direction toggle decides
        XCTAssertTrue(
            StrippingRules.resolved(aggressive: true, stripStageDirections: true).stripStageDirections
        )
        XCTAssertFalse(
            StrippingRules.resolved(aggressive: true, stripStageDirections: false).stripStageDirections
        )
    }

    func testStageDirectionBracketStripsCameraCues() {
        let rules = StrippingRules.aggressive
        let samples = [
            "[Cut to: close-up of the phone]",
            "[B-roll: hand picking up a camera]",
            "[SFX: door slam]",
            "[VO: narration line]",
            "[graphic: pricing table]",
            "[wide shot]",
            "[close up]",
            "[reverse angle]"
        ]
        for sample in samples {
            let body = "before. \(sample) after."
            let result = rules.stageDirectionBracket.removingMatches(in: body)
            XCTAssertFalse(
                result.contains("["),
                "Bracket cue should be stripped: \(sample). Got: \(result)"
            )
            XCTAssertTrue(result.contains("before."))
            XCTAssertTrue(result.contains("after."))
        }
    }

    func testStageDirectionBracketPreservesMarkdownLinksAndWikilinks() {
        let rules = StrippingRules.aggressive
        // A markdown link's text is followed by `(url)`; a wikilink is `[[...]]`.
        // Neither should be consumed by the bracket-cue pattern.
        let link = "see [the docs](https://example.com) for more"
        XCTAssertEqual(rules.stageDirectionBracket.removingMatches(in: link), link)
        let wikilink = "read [[Some Page]] carefully"
        XCTAssertEqual(rules.stageDirectionBracket.removingMatches(in: wikilink), wikilink)
    }

    func testStageDirectionParenStripsPerformanceCues() {
        let rules = StrippingRules.aggressive
        let samples = [
            "(beat)",
            "(pause)",
            "(laughs)",
            "(to camera)",
            "(cont'd)",
            "(sotto)",
            "(whispering)"
        ]
        for sample in samples {
            let body = "line one \(sample) line two"
            let result = rules.stageDirectionParen.removingMatches(in: body)
            XCTAssertFalse(
                result.contains("("),
                "Parenthetical cue should be stripped: \(sample). Got: \(result)"
            )
        }
    }

    func testStageDirectionParenPreservesOrdinaryParentheticals() {
        let rules = StrippingRules.aggressive
        // Legitimate asides must survive — the first token is not a cue word.
        let samples = [
            "the price (about $30) is fair",
            "(see figure 2)",
            "released in (2020)",
            "the app (my favorite) is free"
        ]
        for sample in samples {
            XCTAssertEqual(
                rules.stageDirectionParen.removingMatches(in: sample), sample,
                "Ordinary parenthetical must be preserved: \(sample)"
            )
        }
    }

    func testStageDirectionCapsStripsShotDirections() {
        let rules = StrippingRules.aggressive
        let samples = [
            "and then CUT TO: the anchor desk here",
            "we FADE IN on the scene",
            "a WIDE SHOT establishes place",
            "SMASH CUT TO the reveal",
            "PAN LEFT across the room"
        ]
        for sample in samples {
            let result = rules.stageDirectionCaps.removingMatches(in: sample)
            XCTAssertFalse(
                result.contains("CUT TO")
                || result.contains("FADE IN")
                || result.contains("WIDE SHOT")
                || result.contains("SMASH CUT")
                || result.contains("PAN LEFT"),
                "ALL-CAPS shot direction should be stripped: \(sample). Got: \(result)"
            )
        }
    }

    func testStageDirectionCapsPreservesEmphaticCaps() {
        let rules = StrippingRules.aggressive
        // Ordinary shouted caps that are not recognizable shot directions
        // must survive — no bare common word triggers the caps pass.
        let samples = [
            "I said NO to that offer",
            "this is FREE forever",
            "the answer is YES",
            "INSERTED the key into the lock"  // "INSERT" is not a caps trigger
        ]
        for sample in samples {
            XCTAssertEqual(
                rules.stageDirectionCaps.removingMatches(in: sample), sample,
                "Emphatic caps must be preserved: \(sample)"
            )
        }
    }

    func testStageDirectionLineMatchesWholeCueLines() {
        let rules = StrippingRules.aggressive
        let lines = [
            "WIDE SHOT",
            "Cut to: the anchor desk",
            "CUT TO:",
            "(beat)",
            "[B-roll: the rig]",
            "fade in"
        ]
        for line in lines {
            XCTAssertTrue(
                rules.stageDirectionLine.hasMatch(in: line),
                "Whole-line cue should match: \(line)"
            )
        }
    }

    func testStageDirectionLineIgnoresNormalProse() {
        let rules = StrippingRules.aggressive
        let lines = [
            "welcome to the show",           // "show" is not a line trigger
            "hold on to your hats",          // "hold on" is not a line trigger
            "let me reveal the secret",
            "the camera loves you",
            "this is a normal spoken line",
            "a wide range of options"        // "wide" alone is not "wide shot"
        ]
        for line in lines {
            XCTAssertFalse(
                rules.stageDirectionLine.hasMatch(in: line),
                "Normal prose must NOT match the whole-line cue: \(line)"
            )
        }
    }

    func testGentleKeepsStageDirections() {
        let rules = StrippingRules.gentle
        let body = "before. [Cut to: desk] (beat) after. WIDE SHOT"
        XCTAssertEqual(rules.stageDirectionBracket.removingMatches(in: body), body)
        XCTAssertEqual(rules.stageDirectionParen.removingMatches(in: body), body)
        XCTAssertEqual(rules.stageDirectionCaps.removingMatches(in: body), body)
        XCTAssertFalse(rules.stageDirectionLine.hasMatch(in: "WIDE SHOT"))
    }

    func testAggressiveKeepingStageDirectionsStillStripsLegacyVisualDirection() {
        // The stage-direction-preserving variant keeps the four new patterns
        // inert but leaves the legacy `visualDirection` bracket set active.
        let rules = StrippingRules.aggressiveKeepingStageDirections
        let legacy = "before [B-roll: wide shot] after"
        XCTAssertFalse(
            rules.visualDirection.removingMatches(in: legacy).contains("B-roll")
        )
        // The broadened stage-direction patterns are inert here.
        XCTAssertEqual(
            rules.stageDirectionParen.removingMatches(in: "line (beat) line"),
            "line (beat) line"
        )
    }
}

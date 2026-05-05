//
//  FillerWordsTests.swift
//  OpenPrompterTests
//
//  Unit tests for FillerWords (V2 Feature 5 — Voice-Tracked Auto-Scroll).
//
//  FillerWords supplies a default English set of speech disfluencies
//  ("um", "uh", "ah", "er", "hmm", "mhm") that should be stripped from
//  the recognized-word buffer before script alignment runs.
//
//  Design choice (deliberately conservative): only words that are NOT
//  also valid script vocabulary are in the default set. "like", "you
//  know", "so", "actually", "basically" are common fillers in casual
//  speech but they're also frequently legitimate script words. The
//  default set therefore omits them. Callers that want more aggressive
//  stripping can pass a custom set.
//
//  See V2 Design 03 — Voice Tracking.md §"Algorithm" step 3.
//

import XCTest
@testable import OpenPrompter

final class FillerWordsTests: XCTestCase {

    func testDefaultSetIsNonEmpty() {
        XCTAssertFalse(FillerWords.englishDefault.isEmpty)
    }

    func testDefaultSetContainsCanonicalFillers() {
        // The unambiguous non-script fillers MUST be present.
        XCTAssertTrue(FillerWords.englishDefault.contains("um"))
        XCTAssertTrue(FillerWords.englishDefault.contains("uh"))
        XCTAssertTrue(FillerWords.englishDefault.contains("ah"))
        XCTAssertTrue(FillerWords.englishDefault.contains("er"))
    }

    func testDefaultSetExcludesAmbiguousFillers() {
        // Words that frequently appear in scripts must NOT be stripped
        // by default — otherwise we'd lose legitimate script vocabulary.
        XCTAssertFalse(FillerWords.englishDefault.contains("like"))
        XCTAssertFalse(FillerWords.englishDefault.contains("so"))
        XCTAssertFalse(FillerWords.englishDefault.contains("actually"))
        XCTAssertFalse(FillerWords.englishDefault.contains("you"))
    }

    func testDefaultSetIsAllLowercase() {
        // Filler set is the matching key — comparison is lowercase only.
        for w in FillerWords.englishDefault {
            XCTAssertEqual(w, w.lowercased(), "filler '\(w)' is not lowercase")
        }
    }

    func testStripRemovesFillers() {
        let input = ["welcome", "um", "back", "uh", "to", "the", "show"]
        let output = FillerWords.strip(input)
        XCTAssertEqual(output, ["welcome", "back", "to", "the", "show"])
    }

    func testStripIsCaseInsensitive() {
        let input = ["Hello", "UM", "world", "Uh"]
        let output = FillerWords.strip(input)
        XCTAssertEqual(output, ["Hello", "world"])
    }

    func testStripPreservesOrderAndCase() {
        // Non-filler words keep their original casing — only fillers
        // are removed.
        let input = ["The", "Quick", "Brown", "Fox"]
        let output = FillerWords.strip(input)
        XCTAssertEqual(output, ["The", "Quick", "Brown", "Fox"])
    }

    func testStripEmpty() {
        XCTAssertEqual(FillerWords.strip([]), [])
    }

    func testStripAllFillers() {
        let input = ["um", "uh", "ah", "er"]
        let output = FillerWords.strip(input)
        XCTAssertEqual(output, [])
    }

    func testStripWithCustomSet() {
        let custom: Set<String> = ["like", "totally"]
        let input = ["i", "like", "totally", "agreed"]
        let output = FillerWords.strip(input, using: custom)
        XCTAssertEqual(output, ["i", "agreed"])
    }

    func testStripWithEmptySetIsIdentity() {
        let input = ["um", "hello", "uh"]
        let output = FillerWords.strip(input, using: [])
        XCTAssertEqual(output, input)
    }
}

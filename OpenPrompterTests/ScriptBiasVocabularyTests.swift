//
//  ScriptBiasVocabularyTests.swift
//  OpenPrompterTests
//
//  Unit tests for the pure `ScriptBiasVocabulary` term extractor
//  (V3 Design 05 — SpeechAnalyzer Biasing, Slice A). No device, no Speech
//  import — the extractor is a pure function, so every assertion here runs
//  deterministically in the simulator.
//
//  See V3 Design 05 — SpeechAnalyzer Biasing.md §7 (tests 1–14).
//

import XCTest
@testable import OpenPrompter

final class ScriptBiasVocabularyTests: XCTestCase {

    // Helper: case-insensitive rank of `word` in the result, or nil if absent.
    private func rank(of word: String, in list: [String]) -> Int? {
        list.firstIndex { $0.lowercased() == word.lowercased() }
    }

    // 1
    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(ScriptBiasVocabulary.extract(from: ""), [])
        XCTAssertEqual(ScriptBiasVocabulary.extract(from: "   \n  "), [])
    }

    // 2
    func testStopwordsExcluded() {
        XCTAssertEqual(ScriptBiasVocabulary.extract(from: "the and of to a in that"), [])
    }

    // 3
    func testFillersExcluded() {
        XCTAssertEqual(ScriptBiasVocabulary.extract(from: "um uh er hmm"), [])
    }

    // 4
    func testProperNounMidSentenceScoresHigh() {
        let result = ScriptBiasVocabulary.extract(from: "We deployed Kubernetes today")
        XCTAssertTrue(result.contains("Kubernetes"),
                      "mid-sentence proper noun must be extracted")
        // "We" is sentence-initial and a stopword-ish pronoun — must not
        // outrank the proper noun (in fact it should be absent).
        XCTAssertNil(rank(of: "we", in: result), "'We' must not be biased")
        // "today" is a baseline content word at best; must rank BELOW the
        // proper noun.
        if let kRank = rank(of: "Kubernetes", in: result),
           let tRank = rank(of: "today", in: result) {
            XCTAssertLessThan(kRank, tRank,
                              "proper noun must rank ahead of a baseline word")
        }
    }

    // 5
    func testSentenceInitialCapitalNotTreatedAsProperNoun() {
        // "Today" is sentence-initial → NOT the +3 proper-noun signal.
        // "ran" is a short content word; "quarterization" is a long jargon
        // word that must outrank "Today".
        let result = ScriptBiasVocabulary.extract(
            from: "Today we ran quarterization."
        )
        if let todayRank = rank(of: "Today", in: result),
           let jargonRank = rank(of: "quarterization", in: result) {
            XCTAssertLessThan(jargonRank, todayRank,
                              "sentence-initial capital must NOT get the proper-noun boost")
        } else {
            XCTAssertNotNil(rank(of: "quarterization", in: result),
                            "the long jargon word must be present")
        }
    }

    // 6
    func testAcronymAllCaps() {
        let result = ScriptBiasVocabulary.extract(from: "We shipped the API and SDK")
        XCTAssertTrue(result.contains("API"))
        XCTAssertTrue(result.contains("SDK"))
    }

    // 7
    func testCamelCaseInternalCaps() {
        let result = ScriptBiasVocabulary.extract(from: "We built OpenPrompter with SwiftUI")
        XCTAssertTrue(result.contains("OpenPrompter"), "CamelCase brand kept original-cased")
        XCTAssertTrue(result.contains("SwiftUI"), "internal-caps brand kept original-cased")
    }

    // 8
    func testDigitBearingProductTerm() {
        let result = ScriptBiasVocabulary.extract(from: "The iPhone17 Q3 numbers hit 5 units")
        XCTAssertTrue(result.contains("iPhone17"))
        XCTAssertTrue(result.contains("Q3"))
        // bare small numeric "5" is noise → excluded.
        XCTAssertNil(rank(of: "5", in: result), "bare small numeric must be excluded")
    }

    // 9
    func testLongRareWordScoresAboveShortCommon() {
        // "photorespiration" (16 chars → +2 rarity) vs. "cards" (baseline
        // len-5 content word, score 0). The long word must rank first.
        let result = ScriptBiasVocabulary.extract(from: "We shuffled cards photorespiration")
        guard let longRank = rank(of: "photorespiration", in: result),
              let shortRank = rank(of: "cards", in: result) else {
            return XCTFail("both eligible words should be present: \(result)")
        }
        XCTAssertLessThan(longRank, shortRank,
                          "the 13+ char word must rank above a baseline 4+ char word")
    }

    // 10
    func testCaseInsensitiveDedupePreservesFirstSurfaceForm() {
        let result = ScriptBiasVocabulary.extract(
            from: "We deployed Kubernetes then kubernetes again"
        )
        let matches = result.filter { $0.lowercased() == "kubernetes" }
        XCTAssertEqual(matches.count, 1, "case-insensitive de-dupe yields one entry")
        XCTAssertEqual(matches.first, "Kubernetes",
                       "the first-seen surface form is preserved")
    }

    // 11
    func testFrequencyDoesNotBoost() {
        // "widget" is a baseline content word repeated 40× (score 0 each) —
        // frequency must NOT boost it above the single-occurrence proper
        // noun "Kubernetes" (score +3).
        let repeated = Array(repeating: "widget", count: 40).joined(separator: " ")
        let body = "We use Kubernetes " + repeated
        let result = ScriptBiasVocabulary.extract(from: body)
        let widgetCount = result.filter { $0.lowercased() == "widget" }.count
        XCTAssertEqual(widgetCount, 1, "a 40× word appears exactly once")
        guard let kRank = rank(of: "Kubernetes", in: result),
              let wRank = rank(of: "widget", in: result) else {
            return XCTFail("both terms should be present: \(result)")
        }
        XCTAssertLessThan(kRank, wRank,
                          "a single-occurrence proper noun must outrank a frequent baseline word")
    }

    // 12
    func testCapEnforced() {
        // 300 distinct mid-sentence proper nouns → result capped at 100.
        // Build a single sentence so none is sentence-initial except the
        // very first, then prepend a lowercase lead-in so ALL proper nouns
        // are mid-sentence.
        let nouns = (0..<300).map { "Propernoun\($0)" }.joined(separator: " ")
        let body = "we list " + nouns
        let result = ScriptBiasVocabulary.extract(from: body)
        XCTAssertLessThanOrEqual(result.count, 100, "cap must bound the result at 100")
        XCTAssertGreaterThan(result.count, 90, "a large distinctive corpus should nearly fill the cap")
    }

    // 12b — explicit non-default cap value flows through.
    func testCustomCapEnforced() {
        let nouns = (0..<50).map { "Propernoun\($0)" }.joined(separator: " ")
        let body = "we list " + nouns
        let result = ScriptBiasVocabulary.extract(from: body, cap: 10)
        XCTAssertEqual(result.count, 10)
    }

    // 13
    func testDeterministicOrdering() {
        let body = """
        We deployed Kubernetes on the OpenPrompter cluster. The API and SDK
        shipped iPhone17 Q3 numbers with photorespiration and New York Times
        coverage.
        """
        let a = ScriptBiasVocabulary.extract(from: body)
        let b = ScriptBiasVocabulary.extract(from: body)
        XCTAssertEqual(a, b, "same input twice must yield identical ordered arrays")
    }

    // 14
    func testMultiWordProperNounPhraseEmitted() {
        let result = ScriptBiasVocabulary.extract(from: "the New York Times reported")
        // The phrase (or at least its component proper nouns) must be present.
        let hasPhrase = result.contains("New York Times")
        let hasComponents = result.contains("New") && result.contains("York") && result.contains("Times")
        XCTAssertTrue(hasPhrase || hasComponents,
                      "the multi-word proper-noun phrase or its components must be emitted: \(result)")
        // Stopword / baseline-verb noise must not top the ranking.
        XCTAssertNil(rank(of: "the", in: result), "'the' is a stopword — excluded")
        // "reported" is a baseline content word; if present it must not
        // outrank the proper-noun content.
        if hasPhrase, let phraseRank = rank(of: "New York Times", in: result),
           let reportedRank = rank(of: "reported", in: result) {
            XCTAssertLessThan(phraseRank, reportedRank,
                              "the phrase must rank ahead of a baseline verb")
        }
    }

    // Extra: dotted acronym survives as a single token and scores as acronym.
    func testDottedAcronymRecognized() {
        let result = ScriptBiasVocabulary.extract(from: "we visited the U.S. embassy")
        XCTAssertTrue(result.contains("U.S"),
                      "dotted acronym should survive (trailing dot trimmed): \(result)")
    }

    // Extra: an all-stopword-plus-fillers script yields nothing (no cliff).
    func testAllStopwordsAndFillersReturnsEmpty() {
        XCTAssertEqual(
            ScriptBiasVocabulary.extract(from: "um the and uh of to a in that er"),
            []
        )
    }
}

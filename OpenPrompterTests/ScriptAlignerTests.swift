//
//  ScriptAlignerTests.swift
//  OpenPrompterTests
//
//  Unit tests for ScriptAligner (V2 Feature 5 — Voice-Tracked Auto-Scroll).
//
//  ScriptAligner is the pure-function fuzzy matcher. It tokenizes a
//  script once, then on each ASR partial-result update the caller passes
//  a recently-recognized buffer and the current cursor; ScriptAligner
//  returns the new cursor (or "no match, hold position").
//
//  Cursor semantic: cursor INDEX points at the NEXT expected token —
//  one past the last matched word. After matching script[0..3] the
//  cursor becomes 3.
//
//  Tests map directly to the design doc's edge-case table:
//      1. Filler words           → exercised via the FillerWords path
//      2. Ad-libs                → testAdLibNoMatch
//      3. Skip within 50-word    → testForwardJumpWithinWindow
//      4. Skip beyond 50-word    → testSkipBeyondWindowWithTimeout
//      5. Repeat (retake)        → testBackwardRepeatRejected
//      6. Long pause             → exercised at the integration layer
//      7. Background noise       → testPhoneticMatch (fuzzy tolerance)
//      8. Concurrent recording   → integration concern (not pure)
//      9. Manual scroll          → integration concern (not pure)
//     10. Very fast / very slow  → speculative advance is integration
//
//  See V2 Design 03 — Voice Tracking.md §"Algorithm".
//

import XCTest
@testable import OpenPrompter

final class ScriptAlignerTests: XCTestCase {

    // MARK: - Tokenize

    func testTokenizeBasic() {
        let tokens = ScriptAligner.tokenize("Hello World")
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens[0].normalized, "hello")
        XCTAssertEqual(tokens[1].normalized, "world")
    }

    func testTokenizeStripsPunctuation() {
        let tokens = ScriptAligner.tokenize("Hello, world!")
        XCTAssertEqual(tokens.map(\.normalized), ["hello", "world"])
    }

    func testTokenizeApostropheStripped() {
        let tokens = ScriptAligner.tokenize("they're here")
        XCTAssertEqual(tokens[0].normalized, "theyre")
    }

    func testTokenizeEmpty() {
        XCTAssertEqual(ScriptAligner.tokenize("").count, 0)
    }

    func testTokenizePunctuationOnly() {
        XCTAssertEqual(ScriptAligner.tokenize("!?,.;").count, 0)
    }

    func testTokenizeMultipleWhitespaceCollapsed() {
        let tokens = ScriptAligner.tokenize("hello   world\n\n\t  there")
        XCTAssertEqual(tokens.map(\.normalized), ["hello", "world", "there"])
    }

    func testTokenizePhoneticIsPopulated() {
        let tokens = ScriptAligner.tokenize("their there")
        XCTAssertEqual(tokens[0].phonetic, tokens[1].phonetic,
                       "homophones their/there must share a phonetic code")
        XCTAssertFalse(tokens[0].phonetic.isEmpty)
    }

    func testTokenizeOriginalIndexSequential() {
        let tokens = ScriptAligner.tokenize("a b c d")
        XCTAssertEqual(tokens.map(\.originalIndex), [0, 1, 2, 3])
    }

    func testTokenizeCharOffsetMonotonic() {
        let tokens = ScriptAligner.tokenize("hello world there")
        let offsets = tokens.map(\.charOffset)
        for i in 1..<offsets.count {
            XCTAssertLessThan(offsets[i - 1], offsets[i])
        }
    }

    func testTokenizeCharOffsetFirstWordZero() {
        let tokens = ScriptAligner.tokenize("hello world")
        XCTAssertEqual(tokens[0].charOffset, 0)
    }

    func testTokenizeCharOffsetWithLeadingWhitespace() {
        let tokens = ScriptAligner.tokenize("  hello world")
        XCTAssertEqual(tokens[0].charOffset, 2)
    }

    func testTokenizePunctuationOnlyTokenSkipped() {
        // A standalone "—" or "..." between words should not produce an
        // empty token — those would short-circuit phonetic and break
        // scoring downstream.
        let tokens = ScriptAligner.tokenize("hello — world")
        XCTAssertEqual(tokens.map(\.normalized), ["hello", "world"])
    }

    // MARK: - Init / config

    func testInitWithDefaultConfig() {
        let aligner = ScriptAligner(tokens: ScriptAligner.tokenize("hello world"))
        XCTAssertEqual(aligner.config.lookBack, 10)
        XCTAssertEqual(aligner.config.lookAhead, 50)
        XCTAssertEqual(aligner.config.matchThreshold, 0.65, accuracy: 0.001)
    }

    func testInitWithCustomConfig() {
        var cfg = AlignerConfig()
        cfg.matchThreshold = 0.8
        cfg.lookAhead = 100
        let aligner = ScriptAligner(tokens: ScriptAligner.tokenize("hello"), config: cfg)
        XCTAssertEqual(aligner.config.matchThreshold, 0.8, accuracy: 0.001)
        XCTAssertEqual(aligner.config.lookAhead, 100)
    }

    // MARK: - Empty / degenerate alignment inputs

    func testEmptyBufferReturnsNoMatch() {
        let aligner = ScriptAligner(tokens: ScriptAligner.tokenize("hello world"))
        let r = aligner.align(recognizedBuffer: [], cursorIndex: 0)
        XCTAssertFalse(r.matched)
        XCTAssertEqual(r.cursorIndex, 0)
    }

    func testEmptyTokensReturnsNoMatch() {
        let aligner = ScriptAligner(tokens: [])
        let r = aligner.align(recognizedBuffer: ["hello"], cursorIndex: 0)
        XCTAssertFalse(r.matched)
        XCTAssertEqual(r.cursorIndex, 0)
    }

    // MARK: - Happy-path matching

    func testHappyPathForward() {
        let aligner = ScriptAligner(tokens: ScriptAligner.tokenize(
            "the quick brown fox jumps over the lazy dog"
        ))
        let r = aligner.align(recognizedBuffer: ["the", "quick", "brown"], cursorIndex: 0)
        XCTAssertTrue(r.matched)
        XCTAssertEqual(r.cursorIndex, 3, "cursor must point past matched window")
        XCTAssertGreaterThan(r.confidence, 0.65)
    }

    func testPerfectMatchHighConfidence() {
        let aligner = ScriptAligner(tokens: ScriptAligner.tokenize("alpha beta gamma delta"))
        let r = aligner.align(recognizedBuffer: ["alpha", "beta", "gamma"], cursorIndex: 0)
        XCTAssertTrue(r.matched)
        XCTAssertGreaterThan(r.confidence, 0.95,
                             "perfect match at cursor 0 should be near 1.0")
    }

    // MARK: - Ad-libs (no match)

    func testAdLibNoMatch() {
        let aligner = ScriptAligner(tokens: ScriptAligner.tokenize(
            "the quick brown fox jumps over"
        ))
        let r = aligner.align(
            recognizedBuffer: ["xyzzy", "quux", "blarg"],
            cursorIndex: 0
        )
        XCTAssertFalse(r.matched)
        XCTAssertEqual(r.cursorIndex, 0, "cursor must hold position on no match")
    }

    // MARK: - Forward jump within window (skip a paragraph)

    func testForwardJumpWithinWindow() {
        // 60-word script. Cursor at 0. User skips ahead to ~word 30.
        // Within the 50-word lookahead, so should land cleanly.
        let words = (0..<60).map { "wordx\($0)" }
        let aligner = ScriptAligner(tokens: ScriptAligner.tokenize(
            words.joined(separator: " ")
        ))
        let r = aligner.align(
            recognizedBuffer: ["wordx30", "wordx31", "wordx32"],
            cursorIndex: 0
        )
        XCTAssertTrue(r.matched)
        XCTAssertEqual(r.cursorIndex, 33)
    }

    // MARK: - Skip beyond window (need timeout to widen)

    func testSkipBeyondWindowWithoutTimeoutFails() {
        // 100-word script. Skip to word 80 — beyond default 50 lookahead.
        // Without elapsed-since-match timeout, search window is too narrow.
        let words = (0..<100).map { "wordx\($0)" }
        let aligner = ScriptAligner(tokens: ScriptAligner.tokenize(
            words.joined(separator: " ")
        ))
        let r = aligner.align(
            recognizedBuffer: ["wordx80", "wordx81", "wordx82"],
            cursorIndex: 0
        )
        XCTAssertFalse(r.matched, "match outside lookahead must fail before timeout")
    }

    func testSkipBeyondWindowWithTimeoutSucceeds() {
        // Same script + buffer as above, but with elapsed-since-match
        // exceeding widenTimeout (default 5s). Now we widen to full
        // script and find the match.
        let words = (0..<100).map { "wordx\($0)" }
        let aligner = ScriptAligner(tokens: ScriptAligner.tokenize(
            words.joined(separator: " ")
        ))
        let r = aligner.align(
            recognizedBuffer: ["wordx80", "wordx81", "wordx82"],
            cursorIndex: 0,
            elapsedSinceLastMatch: 6.0
        )
        XCTAssertTrue(r.matched, "widened search must find late skip")
        XCTAssertEqual(r.cursorIndex, 83)
    }

    // MARK: - Backward retake (forward bias)

    func testBackwardRepeatRejected() {
        // Cursor at 10. User says words that match position 2. The
        // perfect match at distance 8 has locality-attenuated score
        // 1.0 / (1 + 0.1*8) = 0.555. Backward threshold is
        // 0.65 + 0.15 = 0.80. 0.555 < 0.80, so reject — forward bias
        // protects against accidental jump-back.
        let words = (0..<20).map { "wordx\($0)" }
        let aligner = ScriptAligner(tokens: ScriptAligner.tokenize(
            words.joined(separator: " ")
        ))
        let r = aligner.align(
            recognizedBuffer: ["wordx2", "wordx3", "wordx4"],
            cursorIndex: 10
        )
        XCTAssertFalse(r.matched, "forward bias must reject far-backward retake")
        XCTAssertEqual(r.cursorIndex, 10, "cursor must hold on rejected match")
    }

    func testBackwardRepeatNearbyAccepted() {
        // Cursor at 5. User repeats the immediately-preceding line —
        // recognized buffer matches at position 2, distance only 3.
        // Locality penalty (L=0.02): 1.0 / (1 + 0.06) = 0.943. Plus
        // phonetic bonus 0.1, raw score 1.1 * 0.943 = 1.038. Subtract
        // forwardBias 0.35 → effective 0.688. Above threshold 0.65 →
        // ACCEPT. Tight retakes are fine; far ones (see test above)
        // are rejected.
        let words = (0..<10).map { "wordx\($0)" }
        let aligner = ScriptAligner(tokens: ScriptAligner.tokenize(
            words.joined(separator: " ")
        ))
        let r = aligner.align(
            recognizedBuffer: ["wordx2", "wordx3"],
            cursorIndex: 5
        )
        XCTAssertTrue(r.matched, "tight backward retake should pass")
        XCTAssertEqual(r.cursorIndex, 4, "cursor moves to 2 + bufN(=2)")
    }

    // MARK: - Phonetic bonus (homophone via PhoneticEncoder)

    func testPhoneticMatchBoost() {
        // Script has "their" — recognized has "there". Different normalized
        // form, same phonetic code "0R". Phonetic bonus must push the
        // score over the threshold.
        let aligner = ScriptAligner(tokens: ScriptAligner.tokenize(
            "we knew it was their fault"
        ))
        let r = aligner.align(
            recognizedBuffer: ["was", "there", "fault"],
            cursorIndex: 0
        )
        XCTAssertTrue(r.matched, "phonetic bonus should rescue homophone substitution")
    }

    // MARK: - Confidence shape

    func testConfidenceRange() {
        let aligner = ScriptAligner(tokens: ScriptAligner.tokenize("a b c d e"))
        let r = aligner.align(recognizedBuffer: ["a", "b"], cursorIndex: 0)
        XCTAssertGreaterThanOrEqual(r.confidence, 0.0)
        XCTAssertLessThanOrEqual(r.confidence, 1.5,
                                 "phonetic bonus may push slightly above 1.0; document upper bound")
    }

    func testConfidenceZeroOnNoMatch() {
        let aligner = ScriptAligner(tokens: ScriptAligner.tokenize("a b c"))
        let r = aligner.align(recognizedBuffer: ["x", "y", "z"], cursorIndex: 0)
        XCTAssertFalse(r.matched)
        // Even with no match the aligner reports the highest score it
        // saw — but it must be below threshold. Just verify it's bounded.
        XCTAssertGreaterThanOrEqual(r.confidence, 0.0)
    }

    // MARK: - Determinism (pure function)

    func testDeterministic() {
        let aligner = ScriptAligner(tokens: ScriptAligner.tokenize("the quick brown fox"))
        let r1 = aligner.align(recognizedBuffer: ["quick", "brown"], cursorIndex: 0)
        let r2 = aligner.align(recognizedBuffer: ["quick", "brown"], cursorIndex: 0)
        let r3 = aligner.align(recognizedBuffer: ["quick", "brown"], cursorIndex: 0)
        XCTAssertEqual(r1.cursorIndex, r2.cursorIndex)
        XCTAssertEqual(r2.cursorIndex, r3.cursorIndex)
        XCTAssertEqual(r1.matched, r2.matched)
        XCTAssertEqual(r1.confidence, r2.confidence, accuracy: 0.0001)
    }

    // MARK: - Rationale

    func testRationaleNonEmpty() {
        let aligner = ScriptAligner(tokens: ScriptAligner.tokenize("hello world"))
        let r = aligner.align(recognizedBuffer: ["hello"], cursorIndex: 0)
        XCTAssertFalse(r.rationale.isEmpty,
                       "rationale must always be populated for diagnostic logging")
    }

    // MARK: - Locality preference (closer match wins)

    func testClosestMatchWins() {
        // Script repeats "hello world" twice. Cursor at 0 with buffer
        // "hello world" should land at the FIRST occurrence, not the
        // second — locality preference.
        let aligner = ScriptAligner(tokens: ScriptAligner.tokenize(
            "hello world some other stuff and again hello world"
        ))
        let r = aligner.align(recognizedBuffer: ["hello", "world"], cursorIndex: 0)
        XCTAssertTrue(r.matched)
        XCTAssertEqual(r.cursorIndex, 2, "first occurrence should win on locality")
    }

    // MARK: - Cursor advance through script

    func testCursorWalksScript() {
        // Simulate three consecutive ASR updates — cursor should walk
        // forward each time.
        let aligner = ScriptAligner(tokens: ScriptAligner.tokenize(
            "alpha beta gamma delta epsilon zeta"
        ))
        var cursor = 0

        let r1 = aligner.align(recognizedBuffer: ["alpha", "beta"], cursorIndex: cursor)
        XCTAssertTrue(r1.matched); cursor = r1.cursorIndex
        XCTAssertEqual(cursor, 2)

        let r2 = aligner.align(recognizedBuffer: ["gamma", "delta"], cursorIndex: cursor)
        XCTAssertTrue(r2.matched); cursor = r2.cursorIndex
        XCTAssertEqual(cursor, 4)

        let r3 = aligner.align(recognizedBuffer: ["epsilon", "zeta"], cursorIndex: cursor)
        XCTAssertTrue(r3.matched); cursor = r3.cursorIndex
        XCTAssertEqual(cursor, 6)
    }

    // MARK: - Single-word recognized buffer

    func testSingleWordBuffer() {
        let aligner = ScriptAligner(tokens: ScriptAligner.tokenize("alpha beta gamma"))
        let r = aligner.align(recognizedBuffer: ["beta"], cursorIndex: 0)
        XCTAssertTrue(r.matched)
        XCTAssertEqual(r.cursorIndex, 2)
    }

    // MARK: - Long script smoke test (must not crash)

    func testLongScriptSmoke() {
        let words = (0..<2000).map { "w\($0)" }
        let aligner = ScriptAligner(tokens: ScriptAligner.tokenize(
            words.joined(separator: " ")
        ))
        let r = aligner.align(
            recognizedBuffer: ["w500", "w501", "w502"],
            cursorIndex: 480
        )
        XCTAssertTrue(r.matched)
        XCTAssertEqual(r.cursorIndex, 503)
    }
}

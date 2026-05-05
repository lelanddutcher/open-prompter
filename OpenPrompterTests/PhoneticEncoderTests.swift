//
//  PhoneticEncoderTests.swift
//  OpenPrompterTests
//
//  Unit tests for PhoneticEncoder (V2 Feature 5 — Voice-Tracked Auto-Scroll).
//
//  The encoder's job is to fold homophones and common ASR near-misses to
//  the same code so ScriptAligner can match "their" / "there" / "they're"
//  even when the speech recognizer transcribes a different spelling.
//
//  Strategy: pragmatic Metaphone-flavored primary code. Not the full
//  Lawrence Philips Double Metaphone (which is ~200 specific rules and
//  produces two codes per word). This is the subset that gets the common
//  English homophone pairs the design doc explicitly cites:
//      - their / there / they're      (TH-fold, vowel-drop)
//      - write / right                (silent W, silent GH)
//      - knight / night               (silent K)
//      - phone / fone                 (PH=F)
//      - knee / nee                   (silent K)
//
//  See V2 Design 03 — Voice Tracking.md §"Algorithm" step 5 for usage
//  context (phonetic match bonus on top of normalized Levenshtein).
//

import XCTest
@testable import OpenPrompter

final class PhoneticEncoderTests: XCTestCase {

    // MARK: - Empty / degenerate inputs

    func testEmptyString() {
        XCTAssertEqual(PhoneticEncoder.encode(""), "")
    }

    func testWhitespaceOnly() {
        XCTAssertEqual(PhoneticEncoder.encode("   "), "")
    }

    func testPunctuationOnly() {
        XCTAssertEqual(PhoneticEncoder.encode("!!!"), "")
    }

    func testSingleVowel() {
        // Initial vowel maps to A.
        XCTAssertEqual(PhoneticEncoder.encode("a"), "A")
    }

    func testSingleConsonant() {
        XCTAssertEqual(PhoneticEncoder.encode("b"), "P")
    }

    // MARK: - Case insensitivity

    func testUppercaseEqualsLowercase() {
        XCTAssertEqual(
            PhoneticEncoder.encode("THERE"),
            PhoneticEncoder.encode("there")
        )
    }

    func testMixedCase() {
        XCTAssertEqual(
            PhoneticEncoder.encode("ThErE"),
            PhoneticEncoder.encode("there")
        )
    }

    // MARK: - Punctuation stripping

    func testApostropheStripped() {
        // "they're" must encode the same as "theyre" once the apostrophe
        // is gone. The design doc's whole point of using a phonetic
        // encoder is to fold these contractions onto their homophones.
        XCTAssertEqual(
            PhoneticEncoder.encode("they're"),
            PhoneticEncoder.encode("theyre")
        )
    }

    func testHyphenStripped() {
        XCTAssertEqual(
            PhoneticEncoder.encode("co-worker"),
            PhoneticEncoder.encode("coworker")
        )
    }

    // MARK: - Determinism

    func testIdempotent() {
        let input = "telegraphics"
        let first = PhoneticEncoder.encode(input)
        let second = PhoneticEncoder.encode(input)
        let third = PhoneticEncoder.encode(input)
        XCTAssertEqual(first, second)
        XCTAssertEqual(second, third)
    }

    // MARK: - Homophone pairs (the design doc's stated reason this exists)

    func testTheirThereTheyre() {
        // All three are homophones in standard English. The encoder
        // MUST collapse them to the same code or the script aligner
        // will mismatch when the ASR picks a different spelling than
        // the script uses.
        let their = PhoneticEncoder.encode("their")
        let there = PhoneticEncoder.encode("there")
        let theyre = PhoneticEncoder.encode("they're")
        XCTAssertEqual(their, there, "their and there must collide")
        XCTAssertEqual(there, theyre, "there and they're must collide")
    }

    func testWriteRight() {
        // Silent W (WR-prefix), silent GH. Both should code to RT-ish.
        XCTAssertEqual(
            PhoneticEncoder.encode("write"),
            PhoneticEncoder.encode("right")
        )
    }

    func testKnightNight() {
        // Silent K (KN-prefix), silent GH. Both should code to NT.
        XCTAssertEqual(
            PhoneticEncoder.encode("knight"),
            PhoneticEncoder.encode("night")
        )
    }

    func testPhoneFone() {
        // PH=F. "fone" is a stand-in for any ASR transcript that picked
        // F instead of PH.
        XCTAssertEqual(
            PhoneticEncoder.encode("phone"),
            PhoneticEncoder.encode("fone")
        )
    }

    func testKneeNee() {
        // Silent K (KN-prefix).
        XCTAssertEqual(
            PhoneticEncoder.encode("knee"),
            PhoneticEncoder.encode("nee")
        )
    }

    func testGnomeNome() {
        // Silent G (GN-prefix).
        XCTAssertEqual(
            PhoneticEncoder.encode("gnome"),
            PhoneticEncoder.encode("nome")
        )
    }

    func testPsychologySychology() {
        // Silent P (PS-prefix). "sychology" stands in for an ASR miss.
        XCTAssertEqual(
            PhoneticEncoder.encode("psychology"),
            PhoneticEncoder.encode("sychology")
        )
    }

    // MARK: - Negative cases (distinct words must NOT collide)

    func testCatNotDog() {
        XCTAssertNotEqual(
            PhoneticEncoder.encode("cat"),
            PhoneticEncoder.encode("dog")
        )
    }

    func testBirdNotFish() {
        XCTAssertNotEqual(
            PhoneticEncoder.encode("bird"),
            PhoneticEncoder.encode("fish")
        )
    }

    func testHelloNotWorld() {
        XCTAssertNotEqual(
            PhoneticEncoder.encode("hello"),
            PhoneticEncoder.encode("world")
        )
    }

    func testTheNotTea() {
        // TH-fold means "the" → "0", "tea" should not collide.
        // (It will be "T" since vowels after the initial drop.)
        XCTAssertNotEqual(
            PhoneticEncoder.encode("the"),
            PhoneticEncoder.encode("tea")
        )
    }

    // MARK: - Specific digraph rules (lock the algorithm shape down)

    func testTHFoldsToZero() {
        // Internal lock: TH must produce a single phonetic-distinct
        // marker we use as "0". This guards against a refactor that
        // accidentally turns TH into T (which would collide "thank"
        // with "tank").
        XCTAssertNotEqual(
            PhoneticEncoder.encode("thank"),
            PhoneticEncoder.encode("tank")
        )
    }

    func testPHFoldsToF() {
        XCTAssertEqual(
            PhoneticEncoder.encode("philip"),
            PhoneticEncoder.encode("filip")
        )
    }

    func testCKFoldsToK() {
        XCTAssertEqual(
            PhoneticEncoder.encode("back"),
            PhoneticEncoder.encode("bak")
        )
    }

    func testCBeforeEFoldsToS() {
        // "cell" → S-L; "sell" → S-L. Soft-C rule.
        XCTAssertEqual(
            PhoneticEncoder.encode("cell"),
            PhoneticEncoder.encode("sell")
        )
    }

    func testCBeforeAStaysK() {
        // "cat" → K-T; "kat" → K-T. Hard-C rule.
        XCTAssertEqual(
            PhoneticEncoder.encode("cat"),
            PhoneticEncoder.encode("kat")
        )
    }

    func testQFoldsToK() {
        XCTAssertEqual(
            PhoneticEncoder.encode("queen"),
            PhoneticEncoder.encode("kween")
        )
    }

    func testZFoldsToS() {
        XCTAssertEqual(
            PhoneticEncoder.encode("zip"),
            PhoneticEncoder.encode("sip")
        )
    }

    func testVFoldsToF() {
        // V → F is a standard Metaphone fold (close phoneme pair, common
        // ASR confusion in noisy environments).
        XCTAssertEqual(
            PhoneticEncoder.encode("very"),
            PhoneticEncoder.encode("fery")
        )
    }

    // MARK: - Vowel handling

    func testInternalVowelsDropped() {
        // "cat" and "cot" both produce K-T (internal vowels drop).
        XCTAssertEqual(
            PhoneticEncoder.encode("cat"),
            PhoneticEncoder.encode("cot")
        )
    }

    func testInitialVowelMapsToA() {
        // All initial vowels normalize to A so "apple" / "epple" /
        // "ipple" share a starting code. Helps with ASR vowel slips.
        XCTAssertEqual(
            String(PhoneticEncoder.encode("apple").prefix(1)),
            "A"
        )
        XCTAssertEqual(
            String(PhoneticEncoder.encode("eagle").prefix(1)),
            "A"
        )
    }

    // MARK: - Doubles collapse

    func testDoubleConsonantsCollapse() {
        // "letter" and "leter" should encode the same.
        XCTAssertEqual(
            PhoneticEncoder.encode("letter"),
            PhoneticEncoder.encode("leter")
        )
    }

    // MARK: - Output shape

    func testOutputIsUppercase() {
        let result = PhoneticEncoder.encode("hello")
        XCTAssertEqual(result, result.uppercased())
    }

    func testOutputIsAscii() {
        // The encoder uses the ASCII alphabet plus "0" for TH and "X"
        // for SH/CH. No lowercase, no diacritics.
        let result = PhoneticEncoder.encode("hello world café")
        for ch in result {
            XCTAssertTrue(
                ch.isASCII,
                "non-ASCII char '\(ch)' in encoded output \(result)"
            )
        }
    }

    // MARK: - Real script snippet (smoke test)

    func testParagraphTokens() {
        // A short paragraph round-tripped through the encoder. Non-empty
        // output, no crashes, deterministic.
        let words = "Welcome back, this is your daily briefing.".split(separator: " ")
        for w in words {
            let encoded = PhoneticEncoder.encode(String(w))
            XCTAssertFalse(encoded.isEmpty, "word '\(w)' encoded to empty")
        }
    }
}

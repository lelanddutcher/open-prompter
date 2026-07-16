//
//  VoiceTrackerTests.swift
//  OpenPrompterTests
//
//  Unit tests for VoiceTracker (V2 Feature 5 — Voice-Tracked Auto-Scroll).
//
//  These tests exercise ONLY the permission state machine and the
//  inject-then-align integration path. The actual SFSpeechRecognizer
//  and audio sample-buffer feeding require a real device and are NOT
//  exercised here. The seam is `suppressDeviceWork: true` on init, plus
//  `prepareTestAuthorization(_:)` to seed status and
//  `ingestRecognizedWords(_:)` to simulate ASR partial results.
//
//  Pattern mirrors `CameraStore`'s `suppressDeviceWork` model — see
//  CameraTests.swift for the equivalent style on the camera side.
//

import XCTest
@testable import OpenPrompter

@MainActor
final class VoiceTrackerTests: XCTestCase {

    // MARK: - Init

    func testInitDefaults() {
        let t = VoiceTracker(suppressDeviceWork: true)
        XCTAssertFalse(t.isActive)
        XCTAssertNil(t.lastMatch)
        XCTAssertEqual(t.authorization, .notDetermined)
        XCTAssertEqual(t.lastRecognizedWords, [])
        XCTAssertEqual(t.currentCursor, 0)
    }

    // MARK: - Permission seam

    func testPrepareTestAuthorizationAuthorized() {
        let t = VoiceTracker(suppressDeviceWork: true)
        t.prepareTestAuthorization(.authorized)
        XCTAssertEqual(t.authorization, .authorized)
    }

    func testPrepareTestAuthorizationDenied() {
        let t = VoiceTracker(suppressDeviceWork: true)
        t.prepareTestAuthorization(.denied)
        XCTAssertEqual(t.authorization, .denied)
    }

    func testPrepareTestAuthorizationRestricted() {
        let t = VoiceTracker(suppressDeviceWork: true)
        t.prepareTestAuthorization(.restricted)
        XCTAssertEqual(t.authorization, .restricted)
    }

    // MARK: - Start gating on authorization

    func testStartFailsWhenNotDetermined() {
        let t = VoiceTracker(suppressDeviceWork: true)
        t.loadScript("hello world")
        // notDetermined: must NOT silently start. Caller is expected to
        // request permission first.
        XCTAssertFalse(t.start())
        XCTAssertFalse(t.isActive)
    }

    func testStartFailsWhenDenied() {
        let t = VoiceTracker(suppressDeviceWork: true)
        t.prepareTestAuthorization(.denied)
        t.loadScript("hello world")
        XCTAssertFalse(t.start())
        XCTAssertFalse(t.isActive)
    }

    func testStartFailsWhenRestricted() {
        let t = VoiceTracker(suppressDeviceWork: true)
        t.prepareTestAuthorization(.restricted)
        t.loadScript("hello world")
        XCTAssertFalse(t.start())
        XCTAssertFalse(t.isActive)
    }

    func testStartFailsWithoutScript() {
        let t = VoiceTracker(suppressDeviceWork: true)
        t.prepareTestAuthorization(.authorized)
        // No loadScript yet — there is nothing to align against.
        XCTAssertFalse(t.start())
        XCTAssertFalse(t.isActive)
    }

    func testStartSucceedsWhenAuthorizedAndScriptLoaded() {
        let t = VoiceTracker(suppressDeviceWork: true)
        t.prepareTestAuthorization(.authorized)
        t.loadScript("hello world there")
        XCTAssertTrue(t.start())
        XCTAssertTrue(t.isActive)
    }

    // MARK: - Stop / restart

    func testStopDeactivates() {
        let t = VoiceTracker(suppressDeviceWork: true)
        t.prepareTestAuthorization(.authorized)
        t.loadScript("hello world")
        XCTAssertTrue(t.start())
        t.stop()
        XCTAssertFalse(t.isActive)
    }

    func testStopAllowsRestart() {
        let t = VoiceTracker(suppressDeviceWork: true)
        t.prepareTestAuthorization(.authorized)
        t.loadScript("hello world")
        _ = t.start()
        t.stop()
        XCTAssertTrue(t.start(), "must be able to restart after stop")
        XCTAssertTrue(t.isActive)
    }

    // MARK: - loadScript reset

    func testLoadScriptResetsState() {
        let t = VoiceTracker(suppressDeviceWork: true)
        t.prepareTestAuthorization(.authorized)
        t.loadScript("first script with several words to align")
        XCTAssertTrue(t.start())
        t.ingestRecognizedWords(["first", "script"])
        XCTAssertGreaterThan(t.currentCursor, 0,
                             "cursor must advance after a forward match")

        t.loadScript("a different script entirely loaded fresh")
        XCTAssertEqual(t.currentCursor, 0)
        XCTAssertNil(t.lastMatch)
        XCTAssertEqual(t.lastRecognizedWords, [])
    }

    // MARK: - Ingest path (filler stripping + alignment)

    func testIngestStripsFillers() {
        let t = VoiceTracker(suppressDeviceWork: true)
        t.prepareTestAuthorization(.authorized)
        t.loadScript("hello world")
        t.ingestRecognizedWords(["welcome", "um", "back", "uh", "to", "show"])
        XCTAssertFalse(t.lastRecognizedWords.contains("um"))
        XCTAssertFalse(t.lastRecognizedWords.contains("uh"))
        XCTAssertTrue(t.lastRecognizedWords.contains("welcome"))
        XCTAssertTrue(t.lastRecognizedWords.contains("back"))
    }

    func testIngestUpdatesMatchWhenActive() {
        let t = VoiceTracker(suppressDeviceWork: true)
        t.prepareTestAuthorization(.authorized)
        t.loadScript("the quick brown fox jumps over")
        XCTAssertTrue(t.start())
        t.ingestRecognizedWords(["the", "quick", "brown"])
        XCTAssertNotNil(t.lastMatch)
        XCTAssertTrue(t.lastMatch?.matched ?? false)
        XCTAssertEqual(t.currentCursor, 3)
    }

    func testIngestSkipsAlignmentWhenInactive() {
        let t = VoiceTracker(suppressDeviceWork: true)
        t.prepareTestAuthorization(.authorized)
        t.loadScript("the quick brown fox")
        // Don't start — isActive remains false.
        t.ingestRecognizedWords(["the", "quick"])
        XCTAssertNil(t.lastMatch, "alignment must not run when inactive")
        XCTAssertEqual(t.currentCursor, 0)
        // Buffer SHOULD still update so callers (e.g., a debug overlay)
        // can show the recognition output.
        XCTAssertEqual(t.lastRecognizedWords, ["the", "quick"])
    }

    func testIngestNoMatchKeepsCursor() {
        let t = VoiceTracker(suppressDeviceWork: true)
        t.prepareTestAuthorization(.authorized)
        t.loadScript("hello world there")
        XCTAssertTrue(t.start())
        t.ingestRecognizedWords(["unrelated", "stuff", "here"])
        XCTAssertNotNil(t.lastMatch)
        XCTAssertFalse(t.lastMatch?.matched ?? true)
        XCTAssertEqual(t.currentCursor, 0)
    }

    func testIngestBufferCappedAtWindowSize() {
        let t = VoiceTracker(suppressDeviceWork: true)
        t.prepareTestAuthorization(.authorized)
        t.loadScript("alpha beta gamma delta epsilon zeta eta theta")
        // Inject 20 distinct words. Buffer must cap at config.windowSize
        // (default 6).
        let words = (0..<20).map { "noise\($0)" }
        t.ingestRecognizedWords(words)
        XCTAssertLessThanOrEqual(t.lastRecognizedWords.count, 6)
    }

    func testIngestAdvancesCursorAcrossCalls() {
        let t = VoiceTracker(suppressDeviceWork: true)
        t.prepareTestAuthorization(.authorized)
        t.loadScript("alpha beta gamma delta epsilon zeta")
        XCTAssertTrue(t.start())

        t.ingestRecognizedWords(["alpha", "beta"])
        XCTAssertEqual(t.currentCursor, 2)

        // Buffer accumulates [alpha, beta, gamma, delta]. Aligner finds
        // the perfect match at script[0..<4]; cursor advances to 4.
        t.ingestRecognizedWords(["gamma", "delta"])
        XCTAssertEqual(t.currentCursor, 4)
    }

    // feedAudio is now nonisolated and non-optional (production path
    // takes a real CMSampleBuffer from the camera audio queue). Its
    // safety when no request is attached is verified by reading the
    // implementation — there's no clean way to construct a CMSample-
    // Buffer in unit tests without dragging AVFoundation into the
    // setup, and the contract is simple: read recognitionRequest, no-
    // op if nil. Real device testing exercises the buffer-append path.

    // MARK: - Contextual-bias vocabulary (V3 Design 05, Slice A)
    //
    // These exercise the wiring between loadScript and the
    // ScriptBiasVocabulary extractor via the `biasVocabularyForTesting`
    // read-only seam. The SpeechAnalyzerBackend itself is device-only
    // (like SFSpeechRecognizer) and is verified on hardware.

    // 15
    func testLoadScriptStringPopulatesBiasVocabulary() {
        let t = VoiceTracker(suppressDeviceWork: true)
        t.prepareTestAuthorization(.authorized)
        t.loadScript("We use Kubernetes")
        XCTAssertTrue(t.biasVocabularyForTesting.contains("Kubernetes"),
                      "String loadScript must populate the bias vocabulary")
    }

    // 16
    func testLoadScriptBlocksPopulatesBiasVocabulary() {
        let t = VoiceTracker(suppressDeviceWork: true)
        t.prepareTestAuthorization(.authorized)
        t.loadScript(blocks: [
            (blockIndex: 0, text: "We deployed OpenPrompter"),
            (blockIndex: 1, text: "with the SwiftUI framework")
        ])
        let vocab = t.biasVocabularyForTesting
        XCTAssertTrue(vocab.contains("OpenPrompter"),
                      "block loadScript must extract from the joined body")
        XCTAssertTrue(vocab.contains("SwiftUI"),
                      "block loadScript must span all blocks")
    }

    // 17
    func testLoadScriptResetsBiasVocabulary() {
        let t = VoiceTracker(suppressDeviceWork: true)
        t.prepareTestAuthorization(.authorized)
        t.loadScript("We use Kubernetes daily")
        XCTAssertFalse(t.biasVocabularyForTesting.isEmpty)

        // A stopword-only script clears the previous vocabulary.
        t.loadScript("the and of to a in that")
        XCTAssertEqual(t.biasVocabularyForTesting, [],
                       "loading an all-stopword script must reset the vocabulary")
    }

    // 18
    func testBiasVocabularyIndependentOfCursor() {
        let t = VoiceTracker(suppressDeviceWork: true)
        t.prepareTestAuthorization(.authorized)
        t.loadScript("alpha Kubernetes beta OpenPrompter gamma SwiftUI delta")
        XCTAssertTrue(t.start())
        let before = t.biasVocabularyForTesting

        // Advance the cursor by ingesting words — the vocabulary must NOT
        // change (unlike the old near-cursor window it replaced).
        t.ingestRecognizedWords(["alpha", "beta"])
        XCTAssertGreaterThan(t.currentCursor, 0,
                             "cursor must advance for this test to be meaningful")
        XCTAssertEqual(t.biasVocabularyForTesting, before,
                       "bias vocabulary must be cursor-independent")
    }

    // 19
    func testSuppressDeviceWorkStartUnaffected() {
        // With suppressDeviceWork, start() must still succeed exactly as
        // before — the backend swap is skipped entirely in suppress mode.
        let t = VoiceTracker(suppressDeviceWork: true)
        t.prepareTestAuthorization(.authorized)
        t.loadScript("We use Kubernetes and OpenPrompter")
        XCTAssertTrue(t.start(), "suppress-mode start must succeed as before")
        XCTAssertTrue(t.isActive)
        // Vocabulary is still populated even though no recognizer starts.
        XCTAssertFalse(t.biasVocabularyForTesting.isEmpty)
    }
}

import XCTest
@testable import OpenPrompter

/// GitHub #10 regression tests.
///
/// The reported symptom was "the voice overlay briefly appears and then
/// immediately closes" on a fully-permissioned iPad. Reproduced on an iPad
/// A16 simulator: `start()` succeeds, `isActive` flips true, and ~1s later
/// the recognition task fails with `kLSRErrorDomain 300 (Failed to
/// initialize recognizer)`. Before the fix that error was discarded at the
/// callback, so voice switched itself off with nothing logged or shown.
///
/// These tests pin the mapping, NOT the device behaviour — they must stay
/// deterministic on every machine.
final class VoiceFailureMessageTests: XCTestCase {

    func testLocalRecognizerFailureGivesActionableDictationGuidance() {
        let msg = VoiceTracker.userFacingMessage(
            forBackendError: "kLSRErrorDomain 300: Failed to initialize recognizer"
        )
        XCTAssertTrue(msg.contains("Dictation"),
                      "must tell the user where to fix it")
        XCTAssertFalse(msg.contains("kLSRErrorDomain"),
                       "raw domain must not leak into user-facing copy")
    }

    /// The message is matched on the human-readable text too, because the
    /// domain string is not guaranteed to be present in every formulation.
    func testFailureMatchedOnDescriptionAloneWithoutDomain() {
        let msg = VoiceTracker.userFacingMessage(
            forBackendError: "Failed to initialize recognizer"
        )
        XCTAssertTrue(msg.contains("Dictation"))
    }

    /// The privacy promise is load-bearing: there is no server fallback, so
    /// the copy must not imply one is coming.
    func testOnDeviceFailureStatesThereIsNoServerFallback() {
        let msg = VoiceTracker.userFacingMessage(
            forBackendError: "kLSRErrorDomain 300: Failed to initialize recognizer"
        )
        XCTAssertTrue(msg.lowercased().contains("never falls back")
                      || msg.lowercased().contains("on-device"))
    }

    /// An unrecognised failure must still surface its raw text — otherwise
    /// the next unknown failure is as undiagnosable as #10 was.
    func testUnknownFailureStillCarriesRawDetail() {
        let msg = VoiceTracker.userFacingMessage(forBackendError: "SomeNewDomain 42: weirdness")
        XCTAssertTrue(msg.contains("SomeNewDomain 42"),
                      "unknown errors must not be swallowed")
    }

    func testNoSpeechDetectedGetsItsOwnMessage() {
        let msg = VoiceTracker.userFacingMessage(forBackendError: "kAFAssistantErrorDomain 1110: No speech detected")
        XCTAssertTrue(msg.lowercased().contains("microphone")
                      || msg.lowercased().contains("speech"))
        XCTAssertFalse(msg.contains("Dictation"),
                       "a no-speech error must not send the user to Dictation settings")
    }
}

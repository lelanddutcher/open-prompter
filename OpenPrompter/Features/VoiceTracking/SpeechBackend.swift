//
//  SpeechBackend.swift
//  OpenPrompter
//
//  V3 Design 05 — SpeechAnalyzer Biasing, Slice B (backend seam).
//
//  A tiny internal protocol so `VoiceTracker` doesn't fork its lifecycle
//  logic across two recognition engines. Both backends deliver words via
//  the SAME callback, which VoiceTracker points at
//  `handleRecognizerResult(allWords:)`. Everything downstream of that
//  entry point (ScriptAligner, the momentum controller, the per-frame
//  ticker) is untouched — only the *producer* of the word stream is
//  swapped.
//
//  `SFSpeechBackend` is a mechanical extraction of the CURRENT
//  `VoiceTracker.start()` body — behavior identical, just relocated
//  behind the protocol. `SpeechAnalyzerBackend` (@available iOS 26+)
//  implements the same contract with the modern SpeechTranscriber /
//  SpeechAnalyzer API (see SpeechAnalyzerBackend.swift).
//
//  See V3 Design 05 — SpeechAnalyzer Biasing.md §4.2.
//

import AVFoundation
import Foundation
import os

/// Voice-tracking start/failure log. GitHub #10: a fully-permissioned iPad
/// showed the overlay for a frame and then closed it with nothing recorded
/// anywhere, because the recognizer's NSError was discarded at the callback.
/// Everything that can refuse to start now says so here.
fileprivate let voiceLog = Logger(
    subsystem: "app.openprompter.ios", category: "voice"
)
import Speech

/// Abstracts "produce a stream of recognized words from the mic."
///
/// Threading contract: `onWords` / `onFinal` / `onError` are invoked on
/// the main actor (each backend hops before calling them). `start()` is
/// called on the main actor. Audio buffers arrive on the backend's own
/// tap queue and are appended without a main hop (matching the current SF
/// `request.append(buffer)` behaviour).
@MainActor
protocol SpeechBackend: AnyObject {
    /// Start recognizing. Returns `true` if the backend has committed to
    /// running (the mic is claimed / recognition is coming up).
    ///
    /// The iOS 26 analyzer backend performs its model-availability check
    /// asynchronously (the SDK's locale/asset APIs are all `async`), so a
    /// synchronous `true` does NOT guarantee the engine survived cold-start.
    /// A backend that discovers post-return that it cannot run calls
    /// `onUnavailable` — VoiceTracker then retries with `SFSpeechBackend`
    /// (§6.2 seamless fallback). `onError` is reserved for a HARD failure
    /// after the engine was running (deactivate, do not silently swap).
    ///
    /// - `onWords`: the cumulative best-transcription word list (same
    ///   semantics as today's `bestTranscription.segments` array).
    /// - `onTranscription`: the formatted cumulative transcription (debug HUD).
    /// - `onFinal`: a natural end of the recognition task (the SF
    ///   `isFinal` analog) so VoiceTracker can re-arm.
    /// - `onUnavailable`: this backend can't run — retry with SF. Called at
    ///   most once, before any `onWords`. `SFSpeechBackend` never calls it.
    /// - `onError`: a hard failure after start so VoiceTracker deactivates.
    ///   Carries a short human-readable reason. GitHub #10: this used to be
    ///   `() -> Void`, so the underlying `NSError` was discarded at the call
    ///   site and the voice overlay just vanished with nothing logged — the
    ///   failure was undiagnosable from a user report. The reason is logged
    ///   and surfaced to the user.
    @discardableResult
    func start(
        locale: Locale,
        contextualStrings: [String],
        onWords: @escaping @MainActor ([String]) -> Void,
        onTranscription: @escaping @MainActor (String) -> Void,
        onFinal: @escaping @MainActor () -> Void,
        onUnavailable: @escaping @MainActor () -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) -> Bool

    /// Tear down recognition + release the audio session claim. Idempotent.
    func stop()
}

// MARK: - SFSpeechBackend

/// The shipped `SFSpeechRecognizer` path, extracted verbatim from
/// `VoiceTracker.start()` so the 17–25 fallback stays byte-for-byte the
/// same. The only behavioural change vs. the old inline code is WHICH
/// `contextualStrings` it receives — the caller now passes the
/// distinctiveness-ranked `ScriptBiasVocabulary` instead of a cursor
/// window (Slice A). The recognizer API is identical.
@MainActor
final class SFSpeechBackend: SpeechBackend {

    private var recognizer: SFSpeechRecognizer?
    /// Apple's `SFSpeechAudioBufferRecognitionRequest` is documented
    /// thread-safe for `append(_:)`. Held nonisolated so the tap queue
    /// can call it without a main-actor hop.
    private nonisolated(unsafe) var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?

    init() {}

    @discardableResult
    func start(
        locale: Locale,
        contextualStrings: [String],
        onWords: @escaping @MainActor ([String]) -> Void,
        onTranscription: @escaping @MainActor (String) -> Void,
        onFinal: @escaping @MainActor () -> Void,
        onUnavailable: @escaping @MainActor () -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) -> Bool {
        // SFSpeechBackend never calls onUnavailable — its availability is
        // knowable synchronously (the guard below), so it either starts or
        // returns false. `onUnavailable` is the analyzer backend's seam.
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            voiceLog.error("SF: no recognizer for locale \(locale.identifier, privacy: .public)")
            return false
        }
        guard recognizer.isAvailable else {
            voiceLog.error("SF: recognizer unavailable for \(locale.identifier, privacy: .public)")
            return false
        }
        self.recognizer = recognizer
        // GitHub #10 diagnostic: on-device support is NOT implied by
        // `isAvailable` (that can be true via the server path). We require
        // on-device, so log the discrepancy — this is the single most likely
        // reason a fully-permissioned device refuses to start.
        voiceLog.info("SF: supportsOnDeviceRecognition=\(recognizer.supportsOnDeviceRecognition, privacy: .public) locale=\(locale.identifier, privacy: .public)")

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On-device only — privacy, no 60s server cap, works offline.
        request.requiresOnDeviceRecognition = true
        // Slice A: distinctiveness-ranked script vocabulary (proper nouns,
        // jargon, product terms) instead of the old near-cursor window. If
        // extraction returned [] we simply don't set contextualStrings —
        // same as an empty window today.
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
        }
        self.recognitionRequest = request

        let task = recognizer.recognitionTask(with: request) { result, error in
            // Callback runs on a background queue. Snapshot Sendable values
            // out of `result`, then hop to main.
            let resultSnapshot: (segments: [String], formatted: String, isFinal: Bool)?
            if let result = result {
                resultSnapshot = (
                    segments: result.bestTranscription.segments.map { $0.substring },
                    formatted: result.bestTranscription.formattedString,
                    isFinal: result.isFinal
                )
            } else {
                resultSnapshot = nil
            }
            // Snapshot the error as a plain string: NSError is not Sendable,
            // and the whole point of #10 is that this value used to be thrown
            // away here.
            let errorReason: String?
            if let error = error as NSError? {
                errorReason = "\(error.domain) \(error.code): \(error.localizedDescription)"
            } else {
                errorReason = nil
            }

            Task { @MainActor in
                if let snap = resultSnapshot {
                    onTranscription(snap.formatted)
                    onWords(snap.segments)
                }
                if let reason = errorReason {
                    voiceLog.error("SF task error: \(reason, privacy: .public)")
                    onError(reason)
                } else if resultSnapshot?.isFinal == true {
                    onFinal()
                }
            }
        }
        self.recognitionTask = task

        // Stand up our own AVAudioEngine input tap so voice tracking
        // captures the mic directly (2.0.4 architecture). Claim the shared
        // audio session through the coordinator first.
        if !startAudioEngineTap(request: request) {
            voiceLog.error("SF: audio engine tap refused to start")
            stop()
            return false
        }
        return true
    }

    /// Build + start an AVAudioEngine input tap that pumps PCM buffers into
    /// `request`. Returns false if the engine refused to start. Extracted
    /// verbatim from VoiceTracker.startAudioEngineTap — same ordering
    /// (claim the session BEFORE reading the input format), same tap size.
    private func startAudioEngineTap(
        request: SFSpeechAudioBufferRecognitionRequest
    ) -> Bool {
        // Claim the shared audio session through the coordinator (fix 1a)
        // instead of racing `setCategory` directly. Best-effort — the engine
        // may still start on the system route, and `engine.start()` throws
        // if not.
        _ = AudioSessionCoordinator.shared.claim(.voiceTracking, configuration: .capture)
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return false }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            return false
        }
        self.audioEngine = engine
        return true
    }

    func stop() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        recognizer = nil
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }
        AudioSessionCoordinator.shared.release(.voiceTracking)
    }
}

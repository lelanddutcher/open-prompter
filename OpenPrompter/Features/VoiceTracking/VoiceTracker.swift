//
//  VoiceTracker.swift
//  OpenPrompter
//
//  V2 Feature 5 — Voice-Tracked Auto-Scroll.
//
//  `SFSpeechRecognizer` wrapper with a `suppressDeviceWork` seam
//  matching `CameraStore`'s pattern.
//
//  Audio architecture: voice tracking SHARES the camera session's
//  audio output. The `feedAudio(_:)` entry point is invoked from
//  `RecordingSession`'s audio sample-buffer delegate (the camera's
//  `AVCaptureAudioDataOutput`). No `AVAudioEngine`, no second mic
//  tap. This means voice tracking only delivers audio while the
//  camera session is running with audio attached — i.e., when the
//  PiP camera is on. Documented design choice (V2 Design 03 §"Audio
//  architecture: shared mic via CMSampleBuffer fork").
//
//  Threading: the public `@MainActor` API drives lifecycle (start /
//  stop / loadScript / state). Audio buffers arrive on the camera
//  audio queue (background) and reach the recognizer via the
//  nonisolated `feedAudio(_:)` method. The recognition request is
//  documented thread-safe by Apple, so we hold it as
//  `nonisolated(unsafe)` and rely on Apple's contract.
//

import AVFoundation
import Foundation
import Observation
import Speech
import os

/// Voice start/stop failure log (GitHub #10).
fileprivate let voiceLogTracker = Logger(
    subsystem: "app.openprompter.ios", category: "voice"
)

/// Speech-recognition authorization status, decoupled from
/// `SFSpeechRecognizerAuthorizationStatus` so tests don't have to
/// import Speech and we have a Sendable surface.
public enum VoiceTrackerAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case authorized

    init(_ apple: SFSpeechRecognizerAuthorizationStatus) {
        switch apple {
        case .notDetermined:
            self = .notDetermined
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        case .authorized:
            self = .authorized
        @unknown default:
            self = .denied
        }
    }
}

@Observable
@MainActor
final class VoiceTracker {

    // MARK: - Public state

    private(set) var authorization: VoiceTrackerAuthorizationStatus

    private(set) var isActive: Bool = false

    /// The most recent alignment result. `nil` until the first ingest
    /// after `start()`. Reset by `loadScript(_:)`.
    private(set) var lastMatch: AlignmentResult?

    /// Last `windowSize` filler-stripped recognized words.
    private(set) var lastRecognizedWords: [String] = []

    /// Cumulative best-transcription string from the recognizer. Useful
    /// for a debug overlay; not used for alignment (we use word-level
    /// segments instead).
    private(set) var lastTranscription: String = ""

    /// RMS amplitude of the most recent audio buffer fed to the
    /// recognizer, in `[0.0, 1.0]`. Throttled to ~20 Hz updates so the
    /// view layer doesn't drown in MainActor hops. Drops to 0 on stop.
    /// Useful for an on-screen meter that confirms mic input is
    /// reaching the recognizer.
    private(set) var audioLevel: Float = 0

    /// Token-index range that's currently visible on screen. When
    /// non-nil, the aligner is constrained to consider ONLY this range
    /// — a generic word like "the" can no longer teleport the cursor
    /// to an offscreen instance. Updated by the view layer as the user
    /// scrolls or changes font size.
    var visibleTokenRange: Range<Int>?

    /// Current believed token position in the script (one past the last
    /// matched word).
    var currentCursor: Int { cursor }

    /// Approximate progress through the loaded script as a fraction
    /// `[0.0, 1.0]`. Computed from the JUST-MATCHED token (cursor - 1)
    /// since the bounding-box model treats the recently-recognized
    /// word as the "active" one that should sit inside the deadzone.
    /// Returns nil when no script is loaded or no match has landed.
    ///
    /// Earlier passes used `cursor` (next-to-read) for a "lead-ahead"
    /// line indicator. With the box model the user thinks in terms of
    /// "where my spoken words appear" — that's the matched word.
    var cursorScriptFraction: Double? {
        guard let aligner = aligner,
              let last = aligner.tokens.last,
              cursor > 0 else { return nil }
        let totalChars = max(1, last.charOffset + last.normalized.count)
        let idx = min(cursor - 1, aligner.tokens.count - 1)
        guard idx >= 0 else { return nil }
        let charOffset = aligner.tokens[idx].charOffset
        return Double(charOffset) / Double(totalChars)
    }

    /// Reason the user-visible voice button should be disabled, or nil
    /// if it should be enabled. Useful for surface UX.
    var ineligibilityReason: String? {
        switch authorization {
        case .notDetermined:
            return nil  // tappable; tap triggers the request
        case .denied:
            return "Speech recognition denied. Enable in Settings."
        case .restricted:
            return "Speech recognition restricted on this device."
        case .authorized:
            return aligner == nil ? "Script not loaded yet." : nil
        }
    }

    // MARK: - Internals

    private let suppressDeviceWork: Bool
    private var aligner: ScriptAligner?
    private var cursor: Int = 0

    /// Distinctive contextual-bias strings for the loaded script (V3
    /// Design 05, Slice A). Rebuilt on every `loadScript(...)`. Fed to
    /// whichever recognizer backend starts, replacing the old near-cursor
    /// window that wasted bias budget on generic filler like "the"/"and".
    /// Empty when the script has no distinctive terms — then we simply
    /// don't set `contextualStrings` (same as an empty window today).
    private var biasVocabulary: [String] = []

    /// 2.0.6: parallel array of `aligner.tokens.count` length where
    /// `tokenToBlock[i]` is the index of the rendered ScriptBlock that
    /// produced token `i`. Empty when loaded via the String-based
    /// `loadScript(_:)` (legacy) — the per-block position math falls
    /// back to the linear-by-char model in that case. Populated by
    /// `loadScript(blocks:)` (the path TeleprompterView uses) so the
    /// view can resolve the matched token's PIXEL position from the
    /// real block frame instead of estimating from char fraction.
    private var tokenToBlock: [Int] = []

    /// 2.0.6: per-block aggregate stats used by `cursorBlockLocation`.
    /// `tokenIndexInBlock` maps token index → its position within the
    /// block's own token list. `tokensPerBlock` maps blockIndex →
    /// total tokens belonging to that block. Together these let us
    /// expose the matched token's WITHIN-BLOCK fraction, which the
    /// view then multiplies by the block's actual rendered height to
    /// get a precise pixel position. Linear-within-block is still an
    /// approximation but it's bounded by one block (typically a few
    /// lines), where character distribution IS roughly uniform.
    private var tokenIndexInBlock: [Int] = []
    private var tokensPerBlock: [Int: Int] = [:]
    /// Last time a successful alignment landed. Reset on `loadScript`.
    /// Public-readable so the view layer can detect silence and halt
    /// scroll momentum (the per-frame ticker freezes the lerp target
    /// after ~1.5 seconds without a match).
    private(set) var lastMatchTime: Date = Date()

    /// The live recognition backend for the current session. Either
    /// `SFSpeechBackend` (shipped path, all iOS versions) or
    /// `SpeechAnalyzerBackend` (iOS 26+, Labs-gated). Owns the recognizer /
    /// request / task / mic engine for its engine. `nil` when not tracking
    /// or in test-suppress mode. (V3 Design 05 §4.2.)
    private var speechBackend: SpeechBackend?

    /// 2.0.4 / DEBUG replay: the recognizer + request + task for the
    /// DEBUG-only `startWithSampleAudio` URL-replay path, which drives
    /// `SFSpeechURLRecognitionRequest` directly rather than through a
    /// `SpeechBackend`. The live-mic path uses `speechBackend` instead.
    private var recognizer: SFSpeechRecognizer?
    /// Apple's `SFSpeechAudioBufferRecognitionRequest` is documented
    /// thread-safe for `appendAudioSampleBuffer`. Held nonisolated so
    /// the camera audio queue can call it without a main-actor hop.
    /// Used ONLY by the legacy `feedAudio(_:)` camera-fork path (dormant
    /// now that the live path is engine-driven) — remains nil on the
    /// backend-driven live path.
    private nonisolated(unsafe) var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// DEBUG replay engine placeholder — the URL replay path feeds itself
    /// from the file, so no live mic engine is needed there. Retained for
    /// teardown symmetry.
    private var audioEngine: AVAudioEngine?

    /// Throttle gate for audio-level publishing — only post one update
    /// every ~50ms to avoid drowning the MainActor in hops at 50 buf/s.
    private nonisolated(unsafe) var lastAudioLevelPostTime: TimeInterval = 0

    // MARK: - Init

    init(suppressDeviceWork: Bool = false) {
        self.suppressDeviceWork = suppressDeviceWork
        if suppressDeviceWork {
            self.authorization = .notDetermined
        } else {
            self.authorization = VoiceTrackerAuthorizationStatus(
                SFSpeechRecognizer.authorizationStatus()
            )
        }
    }

    // MARK: - Script

    /// Tokenize the supplied script and reset rolling state. Must be
    /// called before `start()`. Legacy String path — leaves the
    /// per-block position-resolution map empty, so callers using this
    /// variant fall back to linear-by-char position estimates (less
    /// accurate on scripts with mixed font sizes / headings).
    func loadScript(_ text: String) {
        let tokens = ScriptAligner.tokenize(text)
        self.aligner = ScriptAligner(tokens: tokens)
        self.tokenToBlock = []
        self.tokenIndexInBlock = []
        self.tokensPerBlock = [:]
        self.cursor = 0
        self.lastMatch = nil
        self.lastRecognizedWords = []
        self.lastTranscription = ""
        self.lastMatchTime = Date()
        self.visibleTokenRange = nil
        // Slice A: derive the distinctiveness-ranked bias vocabulary from
        // the whole script body (independent of cursor position).
        self.biasVocabulary = ScriptBiasVocabulary.extract(from: text)
    }

    /// 2.0.6 block-aware load. Each tuple `(blockIndex, text)` has its
    /// own tokenization run; the resulting tokens get tagged with the
    /// block they came from so `cursorBlockLocation` can return a
    /// (blockIndex, withinBlockFraction) pair the view layer maps to
    /// PIXEL positions via real captured block frames. Use this from
    /// the prompter; the linear-by-char fallback in `loadScript(_:)`
    /// is for tests / legacy callers only.
    ///
    /// `charOffset` on emitted tokens is global across the joined
    /// script (block texts joined by `\n\n`) so existing aligner
    /// behaviour is preserved — `charOffset` is only consumed for
    /// `cursorScriptFraction` and `updateVisibleTokenRange`'s
    /// fallback path, both of which want a script-wide ordering.
    func loadScript(blocks: [(blockIndex: Int, text: String)]) {
        var combinedTokens: [ScriptToken] = []
        var tokToBlock: [Int] = []
        var tokIdxInBlock: [Int] = []
        var perBlockCount: [Int: Int] = [:]
        var globalCharBase = 0
        for entry in blocks {
            let blockTokens = ScriptAligner.tokenize(entry.text)
            for (within, tok) in blockTokens.enumerated() {
                combinedTokens.append(ScriptToken(
                    normalized: tok.normalized,
                    phonetic: tok.phonetic,
                    originalIndex: combinedTokens.count,
                    charOffset: globalCharBase + tok.charOffset
                ))
                tokToBlock.append(entry.blockIndex)
                tokIdxInBlock.append(within)
            }
            perBlockCount[entry.blockIndex] = blockTokens.count
            // Match the joined-with-`\n\n` semantics so charOffsets are
            // consistent with what the renderer would see.
            globalCharBase += entry.text.count + 2
        }
        self.aligner = ScriptAligner(tokens: combinedTokens)
        self.tokenToBlock = tokToBlock
        self.tokenIndexInBlock = tokIdxInBlock
        self.tokensPerBlock = perBlockCount
        self.cursor = 0
        self.lastMatch = nil
        self.lastRecognizedWords = []
        self.lastTranscription = ""
        self.lastMatchTime = Date()
        self.visibleTokenRange = nil
        // Slice A: build the joined body the same way the tokens are joined
        // (blocks joined by "\n\n") so the extractor sees the identical text,
        // then derive the bias vocabulary from it.
        let joined = blocks.map(\.text).joined(separator: "\n\n")
        self.biasVocabulary = ScriptBiasVocabulary.extract(from: joined)
    }

    /// 2.0.6: matched token's location for accurate pixel positioning.
    /// Returns `(blockIndex, withinBlockFraction)` — the block the
    /// token came from, and how far through that block (0..1) the
    /// token sits. Returns `nil` when the legacy `loadScript(_:)`
    /// path was used, when no match has landed, or when the cursor
    /// somehow indexes outside the tokenToBlock map (defensive).
    var cursorBlockLocation: (blockIndex: Int, fraction: Double)? {
        guard cursor > 0,
              !tokenToBlock.isEmpty,
              !tokenIndexInBlock.isEmpty else { return nil }
        let idx = min(cursor - 1, tokenToBlock.count - 1)
        guard idx >= 0 else { return nil }
        let blockIndex = tokenToBlock[idx]
        let withinIdx = tokenIndexInBlock[idx]
        let blockTokenCount = tokensPerBlock[blockIndex] ?? 1
        // Fraction = (token index within block + 0.5) / total in block.
        // The +0.5 centers the prediction on the token rather than on
        // its leading edge, so the fraction never quite hits 0 (which
        // would put the token at the literal top of the block frame
        // when we want it slightly below the block's leading edge).
        let denom = max(1, blockTokenCount)
        let fraction = (Double(withinIdx) + 0.5) / Double(denom)
        return (blockIndex, fraction)
    }

    // MARK: - Authorization

    /// Request speech-recognition permission. Closure runs on the main
    /// actor with the resulting status.
    func requestAuthorization(_ completion: @escaping @MainActor (VoiceTrackerAuthorizationStatus) -> Void) {
        if suppressDeviceWork {
            completion(authorization)
            return
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            let mapped = VoiceTrackerAuthorizationStatus(status)
            Task { @MainActor in
                self?.authorization = mapped
                completion(mapped)
            }
        }
    }

    // MARK: - Lifecycle

    /// Begin tracking. Returns `true` if the tracker is now active.
    /// Returns `false` if authorization is missing OR no script is
    /// loaded OR the recognizer cannot be initialized for the device's
    /// locale.
    @discardableResult
    func start() -> Bool {
        guard authorization == .authorized else { return false }
        guard aligner != nil else { return false }
        guard !isActive else { return true }

        if suppressDeviceWork {
            isActive = true
            return true
        }

        // Real path. Choose the recognition backend (V3 Design 05 §4.2).
        // The word stream flows through the SAME handleRecognizerResult
        // sink regardless of backend, so the aligner + momentum controller
        // are untouched — only the PRODUCER of the word stream is swapped.
        //
        // Backend choice is the ONE version branch in the whole feature:
        // iOS 26 SpeechAnalyzer when available AND the Labs pref is on;
        // otherwise the shipped SFSpeechRecognizer path.
        if #available(iOS 26, *), Prefs.voiceUseSpeechAnalyzer {
            let analyzer = SpeechAnalyzerBackend()
            // The analyzer's availability is only knowable asynchronously
            // (§6.2), so a synchronous `true` means "committed to trying".
            // If it discovers it can't run it fires `onUnavailable`, which
            // routes to `fallBackToSFBackend()` — the iOS 26 path can never
            // make tracking worse than today.
            if startBackend(analyzer, contextualStrings: biasVocabulary) {
                self.speechBackend = analyzer
                isActive = true
                lastFailureReason = nil
                return true
            }
            // Synchronous refusal (SpeechTranscriber.isAvailable == false).
            // Fall through to SF immediately.
        }

        // GitHub #10 pre-flight — a WEAK gate, deliberately kept small.
        //
        // Measured on an iPad A16 simulator reproducing #10 exactly:
        //   isAvailable = true, supportsOnDeviceRecognition = TRUE,
        //   and the task still died with
        //   `kLSRErrorDomain 300: Failed to initialize recognizer`.
        //
        // So `supportsOnDeviceRecognition` does NOT predict whether the local
        // recognizer will actually initialize; it can report true while the
        // offline model is absent. This check therefore catches only the
        // honest-false case. The REAL handling for #10 is the error mapping in
        // `userFacingMessage(forBackendError:)` below, which runs after the
        // task fails. Do not delete this, but do not trust it either.
        if let probe = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
           !probe.supportsOnDeviceRecognition {
            lastFailureReason = "On-device dictation isn't available on this device, and Open Prompter never sends audio off-device. Turn on Settings → General → Keyboard → Enable Dictation, then try again. On a managed or school device this may be blocked by policy."
            return false
        }

        let sf = SFSpeechBackend()
        if startBackend(sf, contextualStrings: biasVocabulary) {
            self.speechBackend = sf
            isActive = true
            lastFailureReason = nil
            return true
        }
        if lastFailureReason == nil {
            lastFailureReason = "Voice tracking couldn't claim the microphone. Close other apps using the mic and try again."
        }
        return false
    }

    /// Start `backend`, wiring its word / transcription / final /
    /// unavailable / error callbacks to VoiceTracker's existing sinks.
    /// Returns whether the backend committed to running.
    private func startBackend(
        _ backend: SpeechBackend,
        contextualStrings: [String]
    ) -> Bool {
        backend.start(
            locale: Locale(identifier: "en-US"),
            contextualStrings: contextualStrings,
            onWords: { [weak self] words in
                self?.handleRecognizerResult(allWords: words)
            },
            onTranscription: { [weak self] formatted in
                self?.lastTranscription = formatted
            },
            onFinal: { [weak self] in
                self?.handleBackendFinal()
            },
            onUnavailable: { [weak self] in
                self?.fallBackToSFBackend()
            },
            onError: { [weak self] reason in
                self?.handleBackendError(reason)
            }
        )
    }

    /// The active backend reported it can't run (iOS 26 analyzer model not
    /// installed / locale unsupported / mic refused). Swap to the shipped
    /// SFSpeechRecognizer path WITHOUT bouncing `isActive`, so the swap is
    /// invisible to the user (§6.2 seamless fallback). No-op if we're no
    /// longer active or already on the SF backend.
    private func fallBackToSFBackend() {
        guard isActive else { return }
        // Only the analyzer backend fires onUnavailable; if the current
        // backend is already SF (or gone), there's nothing to swap.
        guard let current = speechBackend, !(current is SFSpeechBackend) else { return }
        current.stop()
        speechBackend = nil

        let sf = SFSpeechBackend()
        if startBackend(sf, contextualStrings: biasVocabulary) {
            speechBackend = sf
            // isActive stays true — the user never sees a gap.
        } else {
            // Even SF refused (no recognizer / mic). Nothing left to try.
            isActive = false
        }
    }

    /// Natural end of a recognition task (SF `isFinal` analog / analyzer
    /// stream end). Matches the shipped 2.0.6 behaviour: tear down and
    /// re-arm so tracking continues seamlessly across the recognizer's
    /// ~30-60s natural stop. Only a hard error deactivates.
    private func handleBackendFinal() {
        tearDownRecognition()
        if isActive {
            // Re-arm. start() rebuilds the backend, engine, and task.
            isActive = false   // start() guards on !isActive
            _ = start()
        }
    }

    /// A backend reported a HARD failure AFTER it had started.
    ///
    /// If the failing backend is the iOS 26 `SpeechAnalyzerBackend`, don't
    /// dead-end voice tracking — fall back to the shipped `SFSpeechBackend`
    /// (the SAME seam the pre-start `onUnavailable` route uses), so a runtime
    /// analyzer error becomes an INVISIBLE swap instead of the voice button
    /// flipping OFF. `isActive` stays true across the swap. Only when the SF
    /// backend ITSELF hard-fails is there nothing left to try — then we
    /// deactivate (matches the shipped SF error branch). (V3 Design 05 §6.2.)
    /// Turn a raw backend error string into something a user can act on.
    ///
    /// GitHub #10: the reporter's overlay "briefly appears and then
    /// immediately closes" with every permission granted. Reproduced on an
    /// iPad A16 simulator: the recognition task fails a beat after start with
    /// `kLSRErrorDomain 300 (Failed to initialize recognizer)` — the on-device
    /// (Local Speech Recognition) engine could not spin up, typically because
    /// the offline dictation model for the locale is not present. We require
    /// on-device (`requiresOnDeviceRecognition = true`) because the app
    /// promises audio never leaves the device, so there is no silent server
    /// fallback to take. The honest resolution is to say what is wrong.
    nonisolated static func userFacingMessage(forBackendError raw: String) -> String {
        if raw.contains("kLSRErrorDomain") || raw.lowercased().contains("failed to initialize recognizer") {
            return "Voice tracking needs Apple's on-device speech model, and it couldn't start on this device. Open Settings → General → Keyboard → Dictation, turn it on, and make sure English is downloaded — then try again. Open Prompter only uses on-device speech, so it never falls back to sending audio to a server."
        }
        if raw.lowercased().contains("no speech") || raw.contains("1110") {
            return "Voice tracking didn't hear any speech. Check the microphone isn't muted or in use by another app."
        }
        return "Voice tracking stopped unexpectedly (\(raw)). Try again, or turn it off and on."
    }

    private func handleBackendError(_ reason: String) {
        if let current = speechBackend, !(current is SFSpeechBackend) {
            fallBackToSFBackend()
            return
        }
        tearDownRecognition()
        isActive = false
        // GitHub #10: record WHY. Previously voice just switched itself off
        // with no trace, which is indistinguishable from a UI bug in a user
        // report. The view surfaces this instead of silently closing.
        lastFailureReason = Self.userFacingMessage(forBackendError: reason)
        voiceLogTracker.error("voice deactivated: \(reason, privacy: .public)")
    }

    /// Why voice tracking last refused to run, or nil if it has not failed
    /// this session. Set on a hard backend failure and cleared on a
    /// successful `start()`. Drives the user-facing message (GitHub #10).
    private(set) var lastFailureReason: String?

    /// Reset the cursor to the start of the script. Use when tracking
    /// has gotten lost and the user wants to start over. Keeps the
    /// loaded aligner; doesn't toggle isActive.
    func resetCursor() {
        cursor = 0
        lastMatch = nil
        lastRecognizedWords = []
        lastTranscription = ""
        lastMatchTime = Date()
    }

    #if DEBUG
    /// DEBUG-only replay path. Drives the recognizer from a bundled or
    /// supplied audio file instead of the live mic, so we can exercise
    /// the alignment + scroll pipeline against a reproducible sample.
    /// Routes results through the same `handleRecognizerResult` path
    /// the live mic uses, so any change in scoring / scroll math gets
    /// tested by replaying the same audio.
    func startWithSampleAudio(url: URL) -> Bool {
        guard authorization == .authorized else { return false }
        guard aligner != nil else { return false }
        guard !isActive else { return true }
        guard !suppressDeviceWork else {
            isActive = true
            return true
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            return false
        }
        self.recognizer = recognizer

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        // Slice A: replay uses the SAME distinctiveness-ranked vocabulary as
        // the live path so replay and live behave identically.
        if !biasVocabulary.isEmpty {
            request.contextualStrings = biasVocabulary
        }

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
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
            let errorSnapshot = (error as NSError?)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let snap = resultSnapshot {
                    self.lastTranscription = snap.formatted
                    self.handleRecognizerResult(allWords: snap.segments)
                }
                // URL replay is one-shot: when the file ends (isFinal)
                // OR an error occurs, deactivate. The live mic path
                // keeps `isActive = true` on isFinal because real
                // sessions are session-scoped; the URL path is not.
                if errorSnapshot != nil || resultSnapshot?.isFinal == true {
                    self.tearDownRecognition()
                    self.isActive = false
                    self.audioLevel = 0
                }
            }
        }
        self.recognitionTask = task
        // No live request — the URL request feeds itself. Set the
        // pointer to nil so feedAudio remains a no-op (samples come
        // from the file, not the camera audio queue).
        self.recognitionRequest = nil

        isActive = true
        return true
    }
    #endif

    /// Stop tracking. Idempotent.
    func stop() {
        if suppressDeviceWork {
            isActive = false
            audioLevel = 0
            return
        }
        tearDownRecognition()
        isActive = false
        audioLevel = 0
    }

    private func tearDownRecognition() {
        // Live path: stop whichever backend is running. The backend owns its
        // recognizer / request / task / mic engine AND releases the audio-
        // session claim (fix 1a) in its own `stop()`.
        if let backend = speechBackend {
            backend.stop()
            speechBackend = nil
        }

        // DEBUG replay path (SFSpeechURLRecognitionRequest): the request +
        // task live directly on VoiceTracker, not behind a backend. Tear
        // them down here.
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        recognizer = nil
        // 2.0.4: stop the audio-engine tap that voice tracking owns.
        // The mic privacy LED in the dynamic island goes off the
        // moment the engine stops — that's the signal the user is
        // looking for ("not currently using your mic").
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }
        // Release our audio-session claim (fix 1a) for the DEBUG replay path
        // (the backend already released for the live path; release() is
        // idempotent per role). If recording still holds `.recording` the
        // coordinator keeps `.capture` applied; otherwise a live volume-
        // button observer is re-armed against `.ambient`.
        if !suppressDeviceWork {
            AudioSessionCoordinator.shared.release(.voiceTracking)
        }
    }

    // MARK: - Audio

    /// Forward a sample buffer from `RecordingSession`'s audio sample-
    /// buffer delegate (camera audio queue) to the recognizer. Safe to
    /// call from any thread; no-op when not active or in test mode.
    /// Also computes RMS amplitude and (throttled) publishes it as
    /// `audioLevel` for the on-screen meter.
    nonisolated func feedAudio(_ sampleBuffer: CMSampleBuffer) {
        // Read the request pointer best-effort. start() / stop() always
        // happen on @MainActor so the pointer is stable across a single
        // delivery.
        guard let request = recognitionRequest else { return }
        request.appendAudioSampleBuffer(sampleBuffer)

        // Audio level → throttled publish. ~20 Hz update rate is plenty
        // for a visual meter and keeps MainActor hops light.
        let now = CACurrentMediaTime()
        if now - lastAudioLevelPostTime >= 0.05 {
            lastAudioLevelPostTime = now
            let level = Self.computeAudioLevel(sampleBuffer)
            Task { @MainActor [weak self] in
                self?.audioLevel = level
            }
        }
    }

    /// Compute RMS amplitude of a sample buffer, scaled to [0, 1].
    /// Handles the two formats AVCaptureAudioDataOutput commonly emits
    /// on iOS (16-bit signed PCM, 32-bit float). Returns 0 for unknown
    /// formats — better silent than wrong.
    nonisolated private static func computeAudioLevel(_ sampleBuffer: CMSampleBuffer) -> Float {
        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let mData = audioBufferList.mBuffers.mData else { return 0 }
        let byteCount = Int(audioBufferList.mBuffers.mDataByteSize)

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return 0
        }
        let flags = asbd.pointee.mFormatFlags
        let bitsPerChannel = Int(asbd.pointee.mBitsPerChannel)
        let isFloat = (flags & kAudioFormatFlagIsFloat) != 0

        var sumSquares: Float = 0
        var count = 0

        if isFloat && bitsPerChannel == 32 {
            count = byteCount / MemoryLayout<Float>.size
            let ptr = mData.bindMemory(to: Float.self, capacity: count)
            for i in 0..<count {
                sumSquares += ptr[i] * ptr[i]
            }
        } else if !isFloat && bitsPerChannel == 16 {
            count = byteCount / MemoryLayout<Int16>.size
            let ptr = mData.bindMemory(to: Int16.self, capacity: count)
            for i in 0..<count {
                let s = Float(ptr[i]) / 32768.0
                sumSquares += s * s
            }
        } else {
            return 0
        }

        guard count > 0 else { return 0 }
        let rms = sqrt(sumSquares / Float(count))
        // Speech RMS sits well below 1.0 even on shouted input — scale
        // up so the meter actually moves visibly. Cap at 1.0.
        return min(1.0, rms * 5.0)
    }

    // MARK: - Recognition path

    /// Production path: replace the rolling buffer with the tail of the
    /// recognizer's cumulative result, then run the aligner.
    private func handleRecognizerResult(allWords: [String]) {
        guard let aligner = aligner, isActive else { return }
        let stripped = FillerWords.strip(allWords)
        let cap = aligner.config.windowSize
        lastRecognizedWords = Array(stripped.suffix(cap))
        runAlignmentIfActive()
    }

    /// Test / synthetic path: APPEND the supplied words to the rolling
    /// buffer, capping at `windowSize`, then run the aligner. Existing
    /// unit tests rely on append semantics.
    func ingestRecognizedWords(_ words: [String]) {
        let stripped = FillerWords.strip(words)
        let cap = aligner?.config.windowSize ?? 6
        let combined = lastRecognizedWords + stripped
        lastRecognizedWords = Array(combined.suffix(cap))
        runAlignmentIfActive()
    }

    private func runAlignmentIfActive() {
        guard let aligner = aligner, isActive else { return }
        let elapsed = Date().timeIntervalSince(lastMatchTime)
        let result = aligner.align(
            recognizedBuffer: lastRecognizedWords,
            cursorIndex: cursor,
            elapsedSinceLastMatch: elapsed,
            visibleRange: visibleTokenRange
        )
        lastMatch = result
        if result.matched {
            cursor = result.cursorIndex
            lastMatchTime = Date()
        }
    }

    /// Recompute `visibleTokenRange` from current scroll geometry. The
    /// view calls this on scroll change, font-size change, and content-
    /// height change. The visible-range constraint then applies on the
    /// NEXT `ingestRecognitionResult` callback. Margin lets words just
    /// off-screen still match — default 2 tokens above and below.
    ///
    /// 2.0.4 padding fix: pre-2.0.4 this function divided the PADDED
    /// `contentHeight` (which includes ~50% viewport top-padding +
    /// ~80% viewport bottom-padding so the script can scroll into
    /// view from mid-screen) by `totalChars`. The resulting
    /// `pxPerChar` was systematically too high, and `scrollOffset /
    /// pxPerChar` mapped to character offsets *past* the actually-
    /// visible window. At large fonts (where bodyHeight dominates
    /// contentHeight) the misalignment was modest; at default font
    /// (~70pt) the visible range started ~60-100 chars beyond where
    /// the user was reading, so the aligner refused to match the
    /// words on screen and tracking appeared broken. Now the caller
    /// passes `bodyTopPad` and `bodyHeight` explicitly so the math
    /// can be in body-relative coordinates.
    func updateVisibleTokenRange(
        scrollOffset: CGFloat,
        viewportHeight: CGFloat,
        contentHeight: CGFloat,
        bodyTopPad: CGFloat = 0,
        bodyHeight: CGFloat = 0,
        margin: Int = 2
    ) {
        guard let aligner = aligner,
              let last = aligner.tokens.last,
              contentHeight > 0 else {
            visibleTokenRange = nil
            return
        }
        // Effective body region. If the caller didn't pass body-
        // relative info, fall back to treating the whole contentHeight
        // as body (legacy behavior, slightly inaccurate but won't
        // crash — preserves backward compatibility for any caller
        // that doesn't migrate at the same time).
        let effectiveBodyHeight: CGFloat
        let topPad: CGFloat
        if bodyHeight > 0 {
            effectiveBodyHeight = bodyHeight
            topPad = bodyTopPad
        } else {
            effectiveBodyHeight = contentHeight
            topPad = 0
        }

        let totalChars = max(1, last.charOffset + last.normalized.count)
        let pxPerChar = effectiveBodyHeight / CGFloat(totalChars)
        guard pxPerChar > 0 else {
            visibleTokenRange = nil
            return
        }

        // Convert pixel viewport span → body-relative span. When the
        // user has scrolled so that the viewport top is still inside
        // the top padding (early script), `topPosOnBody` clamps to 0.
        let topPosOnBody = max(0, scrollOffset - topPad)
        let bottomPosOnBody = max(0, scrollOffset + viewportHeight - topPad)
        let topCharOffset = Int(topPosOnBody / pxPerChar)
        let bottomCharOffset = Int(bottomPosOnBody / pxPerChar)

        // Linear scan — tokens are sorted by charOffset so this is
        // O(n) once. For typical scripts (<5000 tokens) trivially fast.
        var startIdx = aligner.tokens.count
        var endIdx = aligner.tokens.count
        for (i, tok) in aligner.tokens.enumerated() {
            if startIdx == aligner.tokens.count, tok.charOffset >= topCharOffset {
                startIdx = i
            }
            if tok.charOffset > bottomCharOffset {
                endIdx = i
                break
            }
        }
        let initialLo = max(0, startIdx - margin)
        let initialHi = min(aligner.tokens.count, endIdx + margin)

        // 2.0.5: at very large fonts the visible body covers only
        // 5-10 tokens. If the recognizer's first match doesn't
        // happen to land inside that window, the cursor never
        // advances and the user sees voice tracking "do nothing."
        // Below a minimum range size, expand symmetrically around
        // the current cursor to give the aligner enough candidate
        // tokens to find a real match. The cursor's locality bias
        // still prevents distant teleportation; this just relaxes
        // the cap when the window is too tight to contain a typical
        // recognizer hypothesis.
        let minRangeSize = 12
        let lo: Int
        let hi: Int
        if initialHi - initialLo < minRangeSize {
            let center = cursor > 0
                ? min(cursor - 1, aligner.tokens.count - 1)
                : (initialLo + initialHi) / 2
            let half = minRangeSize / 2 + margin
            lo = max(0, center - half)
            hi = min(aligner.tokens.count, center + half)
        } else {
            lo = initialLo
            hi = initialHi
        }
        visibleTokenRange = lo < hi ? lo..<hi : nil
    }

    // MARK: - Test seams

    /// Seed authorization status for unit tests. No-op in production.
    func prepareTestAuthorization(_ status: VoiceTrackerAuthorizationStatus) {
        guard suppressDeviceWork else { return }
        self.authorization = status
    }

    /// Read-only view of the extracted contextual-bias vocabulary (V3
    /// Design 05, Slice A) for unit tests. Populated by `loadScript(...)`;
    /// independent of the cursor. `internal` so `@testable import` reaches
    /// it without exposing a mutation surface.
    var biasVocabularyForTesting: [String] { biasVocabulary }
}

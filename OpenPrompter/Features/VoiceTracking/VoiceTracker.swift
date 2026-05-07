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

    private var recognizer: SFSpeechRecognizer?
    /// Apple's `SFSpeechAudioBufferRecognitionRequest` is documented
    /// thread-safe for `appendAudioSampleBuffer`. Held nonisolated so
    /// the camera audio queue can call it without a main-actor hop.
    private nonisolated(unsafe) var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// 2.0.4: VoiceTracker now grabs the microphone directly via
    /// `AVAudioEngine` instead of forwarding from the camera's
    /// `AVCaptureAudioDataOutput`. Old architecture required the user
    /// to enable PiP/camera before voice tracking could receive any
    /// audio at all (the comment at the top of this file documented
    /// the dependency). Founder feedback: voice tracking should grab
    /// the mic itself when activated — and should show the orange
    /// "mic in use" indicator in the dynamic island, which only fires
    /// when the audio engine is actively tapping the input. This
    /// removes the cross-feature ordering trap entirely.
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

        // Real path. Build the recognizer + request + task.
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            return false
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On-device only — privacy, no 60s server cap, works offline.
        request.requiresOnDeviceRecognition = true
        // Bias recognition toward words NEAR THE CURRENT CURSOR. Feeding
        // the entire script's vocabulary made common words match at far
        // positions ("say 'the' once at start, recognizer hears 'the',
        // aligner finds 'the' at end of script"). A sliding ~100-word
        // window near the cursor keeps the recognizer's prior consistent
        // with where we expect the user to be.
        //
        // SFSpeechRecognizer doesn't reapply contextualStrings mid-task,
        // so this snapshot reflects the cursor at start time only. A
        // future pass can periodically restart the recognition task as
        // the cursor advances; for now, short scripts get the whole
        // vocabulary and long scripts get a forward-biased window.
        if let aligner = aligner {
            let from = max(0, cursor - 10)
            let nearCursor = aligner.tokens
                .dropFirst(from)
                .prefix(100)
                .map(\.normalized)
            let unique = Array(Set(nearCursor))
            request.contextualStrings = unique
        }
        self.recognitionRequest = request

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Callback runs on a background queue. Hop to main and
            // process. Capture only Sendable values out of `result`.
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
                // The recognizer task ends on `isFinal` or error. Tear
                // down so the next start() builds a fresh request.
                //
                // 2.0.6 fix: SFSpeechRecognizer (especially with
                // requiresOnDeviceRecognition) ends naturally after
                // ~30-60 seconds with `isFinal == true`. Pre-2.0.6 we
                // tore down WITHOUT setting isActive=false, so voice
                // tracking thought it was running but had no
                // recognition machinery — voice tracking "fell off
                // rapidly" exactly as the user reported. Now: on a
                // natural isFinal end, restart so tracking continues
                // seamlessly. Only a hard error sets isActive=false.
                if errorSnapshot != nil {
                    self.tearDownRecognition()
                    self.isActive = false
                } else if resultSnapshot?.isFinal == true {
                    self.tearDownRecognition()
                    if self.isActive {
                        // Re-arm. start() rebuilds the request, the
                        // engine, and the recognition task.
                        self.isActive = false   // start() guards on !isActive
                        _ = self.start()
                    }
                }
            }
        }
        self.recognitionTask = task

        // 2.0.4: stand up our own AVAudioEngine input tap so voice
        // tracking captures the mic directly, no camera dependency.
        // The tap forwards PCM buffers into the recognition request
        // (and posts an audio-level reading for the HUD meter, same
        // throttle as the old camera-buffer path).
        if !startAudioEngineTap(request: request) {
            // Engine setup failed — tear the request down so a retry
            // is clean.
            tearDownRecognition()
            return false
        }

        isActive = true
        return true
    }

    /// Build + start an AVAudioEngine input tap that pumps PCM buffers
    /// into `request`. Returns false if the engine refused to start
    /// (no input available, audio session in a conflicting category,
    /// etc.) so the caller can roll back the recognition request.
    ///
    /// Audio session note: the engine works inside the
    /// `.playAndRecord` / `.videoRecording` category set by
    /// `RecordingSession.configureAudioSession`. We don't reconfigure
    /// the session here — recording and voice tracking can both
    /// observe the mic in that category, and changing it underneath a
    /// running camera capture would interrupt video audio.
    private func startAudioEngineTap(
        request: SFSpeechAudioBufferRecognitionRequest
    ) -> Bool {
        // 2.0.5 ordering fix: configure the audio session for record
        // BEFORE reading the input node's outputFormat. Pre-2.0.5
        // we read the format first; on a fresh launch with camera
        // OFF (no prior session activation), the input bus has no
        // format yet (sampleRate == 0), the early-return tripped,
        // and voice tracking silently failed. Activating the
        // session first ensures the input bus advertises a valid
        // format. Idempotent if RecordingSession already activated
        // for video recording.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .videoRecording,
                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setActive(true, options: [])
        } catch {
            // Best-effort — engine may still start on the system
            // route. If it doesn't, `engine.start()` below throws.
        }
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
        if let aligner = aligner {
            let from = max(0, cursor - 10)
            let nearCursor = aligner.tokens
                .dropFirst(from)
                .prefix(100)
                .map(\.normalized)
            let unique = Array(Set(nearCursor))
            request.contextualStrings = unique
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
}

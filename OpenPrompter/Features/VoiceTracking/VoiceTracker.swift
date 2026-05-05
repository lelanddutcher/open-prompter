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

    /// Current believed token position in the script (one past the last
    /// matched word).
    var currentCursor: Int { cursor }

    /// Approximate progress through the loaded script as a fraction
    /// `[0.0, 1.0]`. Computed from the NEXT-to-be-read token's
    /// character offset divided by total script length. Returns nil
    /// when no script is loaded or the cursor is at 0.
    ///
    /// Why "next-to-be-read" rather than "just-matched"? The reading
    /// line on screen marks "what to say next" — the matched word
    /// should land ABOVE the line by the time the user has spoken it,
    /// with the upcoming word AT the line. Using the cursor index
    /// directly (one past the matched word) gives the lead-ahead
    /// behavior teleprompter readers expect.
    var cursorScriptFraction: Double? {
        guard let aligner = aligner,
              let last = aligner.tokens.last,
              cursor > 0 else { return nil }
        let totalChars = max(1, last.charOffset + last.normalized.count)
        let idx = min(cursor, aligner.tokens.count - 1)
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
    private var lastMatchTime: Date = Date()

    private var recognizer: SFSpeechRecognizer?
    /// Apple's `SFSpeechAudioBufferRecognitionRequest` is documented
    /// thread-safe for `appendAudioSampleBuffer`. Held nonisolated so
    /// the camera audio queue can call it without a main-actor hop.
    private nonisolated(unsafe) var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

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
    /// called before `start()`.
    func loadScript(_ text: String) {
        let tokens = ScriptAligner.tokenize(text)
        self.aligner = ScriptAligner(tokens: tokens)
        self.cursor = 0
        self.lastMatch = nil
        self.lastRecognizedWords = []
        self.lastTranscription = ""
        self.lastMatchTime = Date()
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
                if errorSnapshot != nil || resultSnapshot?.isFinal == true {
                    self.tearDownRecognition()
                    if errorSnapshot != nil { self.isActive = false }
                }
            }
        }
        self.recognitionTask = task

        isActive = true
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
            elapsedSinceLastMatch: elapsed
        )
        lastMatch = result
        if result.matched {
            cursor = result.cursorIndex
            lastMatchTime = Date()
        }
    }

    // MARK: - Test seams

    /// Seed authorization status for unit tests. No-op in production.
    func prepareTestAuthorization(_ status: VoiceTrackerAuthorizationStatus) {
        guard suppressDeviceWork else { return }
        self.authorization = status
    }
}

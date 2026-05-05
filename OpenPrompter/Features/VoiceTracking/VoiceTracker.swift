//
//  VoiceTracker.swift
//  OpenPrompter
//
//  V2 Feature 5 — Voice-Tracked Auto-Scroll.
//
//  Skeleton wrapper around `SFSpeechRecognizer` with a
//  `suppressDeviceWork` seam mirroring `CameraStore`'s pattern. Owns:
//
//  - Speech-recognition authorization status (mapped to a public enum
//    so tests don't need to import Speech).
//  - The active/inactive flag.
//  - The script's `ScriptAligner` and the rolling cursor / recognized
//    buffer that drives it.
//
//  This step deliberately leaves THREE integration points for later
//  passes (steps 4-7 in `V2 Design 03 — Voice Tracking.md`):
//
//    1. The actual `SFSpeechRecognizer` + recognition-task wiring in
//       `start()` / `stop()` is stubbed. Real recognition needs device
//       hardware and runs in step 4 (or later).
//    2. `feedAudio(_:)` accepts a `CMSampleBuffer?` so tests can pass
//       `nil`. Step 5 (the audio fork in `RecordingSession`) feeds real
//       buffers.
//    3. Permission request is async-ready but no UI driver is wired.
//
//  See `OpenPrompter/Features/Camera/CameraStore.swift` for the
//  reference implementation of the `suppressDeviceWork` pattern.
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

    /// Last `windowSize` filler-stripped recognized words, in the
    /// order they arrived. Useful for debug overlays AND for the
    /// aligner to consume.
    private(set) var lastRecognizedWords: [String] = []

    /// Current believed token position in the script (one past the last
    /// matched word). Read-only externally; mutated by ingest.
    var currentCursor: Int { cursor }

    // MARK: - Internals

    private let suppressDeviceWork: Bool
    private var aligner: ScriptAligner?
    private var cursor: Int = 0
    private var lastMatchTime: Date = Date()

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
        self.lastMatchTime = Date()
    }

    // MARK: - Authorization

    /// Request speech-recognition permission. The closure is invoked on
    /// the main actor with the new authorization status.
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

    /// Begin tracking. Returns `true` if the tracker is now active. A
    /// false return means either authorization is missing OR no script
    /// has been loaded yet.
    @discardableResult
    func start() -> Bool {
        guard authorization == .authorized else { return false }
        guard aligner != nil else { return false }

        if suppressDeviceWork {
            isActive = true
            return true
        }

        // Real path (deferred to a later step):
        //   - create SFSpeechAudioBufferRecognitionRequest
        //   - configure: requiresOnDeviceRecognition = true,
        //                shouldReportPartialResults = true,
        //                contextualStrings = scriptVocabulary()
        //   - start SFSpeechRecognitionTask, route partial results to
        //     ingestRecognizedWords(_:)
        //
        // Step 3 commits the skeleton; the recognition loop ships in
        // step 4 once it can be device-tested.
        isActive = true
        return true
    }

    /// Stop tracking. Idempotent.
    func stop() {
        if suppressDeviceWork {
            isActive = false
            return
        }
        // Real path (deferred):
        //   - cancel recognition task
        //   - end audio request
        isActive = false
    }

    // MARK: - Audio

    /// Forward a sample buffer from the camera session's audio output
    /// to the speech recognizer. Step 5 calls this from
    /// `RecordingSession`'s audio delegate. No-op in test mode and when
    /// the tracker is inactive.
    func feedAudio(_ sampleBuffer: CMSampleBuffer?) {
        guard isActive, !suppressDeviceWork, let _ = sampleBuffer else { return }
        // Real path (deferred):
        //   request?.appendAudioSampleBuffer(sampleBuffer)
    }

    // MARK: - Recognition path

    /// Process recognized words. Strips fillers, caps the rolling
    /// buffer at `windowSize`, and (when active) runs the aligner —
    /// updating `lastMatch` and the cursor on a successful match.
    ///
    /// In production this is called by the `SFSpeechRecognitionTask`
    /// result handler with the partial-result transcription. In tests
    /// it's the seam for synthetic "the user said X" injection.
    func ingestRecognizedWords(_ words: [String]) {
        let stripped = FillerWords.strip(words)
        let cap = aligner?.config.windowSize ?? 6
        let combined = lastRecognizedWords + stripped
        lastRecognizedWords = Array(combined.suffix(cap))

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

    /// Seed authorization status for unit tests. No-op outside test
    /// mode — the production path always reads `SFSpeechRecognizer`
    /// directly.
    func prepareTestAuthorization(_ status: VoiceTrackerAuthorizationStatus) {
        guard suppressDeviceWork else { return }
        self.authorization = status
    }
}

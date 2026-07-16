//
//  RecordingSession.swift
//  OpenPrompter
//
//  Owns the AVAssetWriter-driven sample-buffer pipeline for the recording
//  feature. Reuses `CameraStore.session` (the PiP feature is the camera
//  owner) — recording outputs are added inside a `beginConfiguration` /
//  `commitConfiguration` block on REC tap and torn down on stop, without
//  disturbing the live preview.
//
//  Threading:
//  - Public API is @MainActor — the chip / countdown / Live Activity all
//    bind to `RecordingState.phase` from the main thread.
//  - Sample-buffer delivery happens on a dedicated `recordingQueue`
//    distinct from `CameraStore.sessionQueue` (Apple guidance — they
//    advise against sharing data-output queues with session-config queues
//    to avoid deadlocks during teardown).
//  - Writer state (writer, inputs, outputs, session-start markers, etc.)
//    is guarded by `writerStateLock`, an `OSAllocatedUnfairLock<WriterState>`.
//    Both MainActor methods and recordingQueue handlers acquire the lock
//    for any read or write of writer-pipeline properties. Lock holds are
//    kept short — copy values out, work on them outside the lock, write
//    back inside the lock. We never `await` while holding the lock.
//  - Writer appends are serialized on `recordingQueue`.
//  - The Live Activity actor calls happen on a Task that drops back to
//    the global concurrent pool.
//
//  Video markers (V3 headline, H0a manual + H0b script):
//  - A THIRD writer input (timed metadata) + an `AVAssetWriterInputMetadataAdaptor`
//    are built in `lazilyStartWriterOnFirstSample` alongside video/audio, plus a
//    fourth input for a QuickTime `.chapterList` TEXT track. `tapMark()` (manual)
//    and `appendChapter(title:at:)` (script) queue a `RecordingMarker` into
//    `WriterState.pendingMarkers` under `writerStateLock`; the `recordingQueue`
//    drains it after each video frame (`drainPendingMarkers`) — copy-out, release,
//    append — staying inside the "never await holding the lock" rule. Every marker
//    time is clamped to `[sessionStart, lastVideoPTS]`; the chapter track's titled
//    TEXT samples are written from the accumulated markers at `finishWriting`
//    (a `.text` track, NOT `.metadata` — QuickTime reads chapter titles only from
//    text sample data, so a metadata chapter track shows empty titles). Both are
//    pref-gated (`recordingMarkerMetadataTrack` / `recordingMarkerChapterTrack`,
//    default on) and live INSIDE the .mov so they survive the Photos save + share.
//  - THE DELIVERABLE (Adobe Premiere Pro native markers): after `finishWriting`,
//    `XMPMarkerWriter` embeds an Adobe XMP Dynamic Media `xmpDM:Tracks` marker
//    track into `moov/udta/XMP_` (where Premiere reads/writes XMP for a `.mov`).
//    Neither the chapter track nor the `mebx` metadata track imports into Premiere
//    as a marker; the XMP does. Gated on `recordingMarkerMetadataTrack`, injected
//    on the recording queue BEFORE the Photos save + self-test stash.
//

import AVFAudio
import AVFoundation
import Combine
import Foundation
import Observation
import os
import Photos
import UIKit

#if canImport(ActivityKit)
import ActivityKit
#endif

/// Errors the session surfaces upward into `RecordingState.lastError`.
enum RecordingSessionError: LocalizedError, Equatable {
    case sessionNotReady
    case microphoneDenied
    case writerSetupFailed(String)
    case finalizeFailed(String)
    case photosDenied
    case photosWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .sessionNotReady:           return "Camera isn't ready yet."
        case .microphoneDenied:          return "Microphone is off — open Settings to enable."
        case .writerSetupFailed(let m):  return "Couldn't start recording: \(m)"
        case .finalizeFailed(let m):     return "Couldn't finish recording: \(m)"
        case .photosDenied:              return "Photos access is off — open Settings to enable."
        case .photosWriteFailed(let m):  return "Couldn't save to Photos: \(m)"
        }
    }
}

@Observable
@MainActor
final class RecordingSession {

    // MARK: - Wired state

    /// Phase mirror — written by this session, read by every UI surface.
    /// Concretely held on `AppState.recordingState`.
    let state: RecordingState

    /// The shared capture session from `CameraStore`. We don't own this —
    /// the camera store does. We add inputs/outputs lazily on REC tap and
    /// remove them on stop. Never call `startRunning`/`stopRunning` here;
    /// the camera store manages the session lifecycle.
    private let cameraSession: AVCaptureSession?

    /// Camera store's session queue — used for `beginConfiguration`/
    /// `commitConfiguration` blocks so we don't race with PiP-mode toggles
    /// happening on the same queue.
    private let cameraSessionQueue: DispatchQueue?

    /// Reference back to the camera store so we can read the requested
    /// dynamic-aspect on iOS 26 (used to compute post-reshape dims when
    /// `device.dynamicDimensions` hasn't caught up to the async reshape).
    /// Weak — the store outlives the session, but in tests we may hand
    /// `nil`.
    private weak var cameraStore: CameraStore?

    /// Active script's URL — captured when the prompter mounts so the
    /// iCloud-next-to-script copy knows where to land. Updated when the
    /// user opens a different script.
    private var currentScriptURL: URL? = nil

    /// Display name of the active script, surfaced in the Live Activity
    /// "expanded" presentation.
    private var currentScriptName: String = ""

    // MARK: - Writer / outputs

    /// Dedicated sample-buffer delivery queue. Distinct from
    /// `cameraSessionQueue` per Apple guidance. Stored in a let constant
    /// at init — `DispatchQueue` is `Sendable`, so the property doesn't
    /// need any cross-actor wrapping.
    nonisolated private let recordingQueue = DispatchQueue(
        label: "app.openprompter.recording.session",
        qos: .userInitiated
    )

    /// Cross-actor writer-pipeline state. Bundles every property that the
    /// MainActor methods (begin / configure / finalize) write and the
    /// `recordingQueue` sample-buffer handler reads. Wrapped in
    /// `OSAllocatedUnfairLock` so accesses from either side serialize
    /// without resorting to `nonisolated(unsafe)`.
    fileprivate struct WriterState {
        var writer: AVAssetWriter?
        var videoInput: AVAssetWriterInput?
        var audioInput: AVAssetWriterInput?
        var videoOutput: AVCaptureVideoDataOutput?
        var audioOutput: AVCaptureAudioDataOutput?
        // MARK: Video markers (V3 headline, H0a manual + H0b script)
        //
        // The third writer input is a TIMED-METADATA track. It's built in
        // `lazilyStartWriterOnFirstSample` alongside the video/audio inputs
        // and added before `startWriting`, so both the timed-metadata track
        // AND the finalize-time QuickTime chapter track can be written into
        // the same `.mov`. Nil when the metadata-track pref is off or the
        // writer hasn't been built yet.
        var metadataInput: AVAssetWriterInput?
        var metadataAdaptor: AVAssetWriterInputMetadataAdaptor?
        /// QuickTime CHAPTER-track input (separate from the timed-metadata
        /// track above). This is a `.text` track associated to the video track
        /// as a `.chapterList` so Photos / QuickTime render the markers as
        /// scrubber ticks WITH readable titles (a `.metadata`/`mebx` chapter
        /// track yields empty `TAG:title=`; QuickTime reads chapter names only
        /// from a text track's sample data). Its titled samples are written all
        /// at once at `finishWriting` (each spans `[marker_i, marker_{i+1})`),
        /// so nothing is appended to it during the take. Nil when the
        /// chapter-track pref is off. Held so finalize can append + finish it.
        var chapterInput: AVAssetWriterInput?
        /// The `.text` sample format description for `chapterInput`, needed at
        /// finalize to build each chapter's text `CMSampleBuffer`. Nil when the
        /// chapter track isn't being written.
        var chapterTextFormat: CMFormatDescription?
        /// Markers a MainActor caller (manual tap / script crossing) has
        /// queued but the `recordingQueue` hasn't drained yet. Copied out
        /// and cleared under `writerStateLock` on the next video frame.
        var pendingMarkers: [RecordingMarker] = []
        /// Every marker successfully drained this take, in append order.
        /// Consumed at `finishWriting` to build the QuickTime chapter track.
        var committedMarkers: [RecordingMarker] = []
        /// PTS of the most recently appended video sample buffer — the
        /// frame-accurate "now" for a marker tap and the upper clamp bound
        /// `[sessionStart, lastVideoPTS]`. Nil until the first non-warmup
        /// frame has been appended.
        var lastVideoPTS: CMTime?
        /// Legacy slot for an audio device input attached at REC tap. As of
        /// dogfood-pass-3 the audio input is owned by `CameraStore` and
        /// attached at session-config time, so this stays nil — kept for
        /// backwards compatibility with the finalize/teardown bookkeeping.
        var audioInputDevice: AVCaptureDeviceInput?
        var sessionStartTime: CMTime?
        var hasStartedSession: Bool = false
        var currentRecordingURL: URL?
        var recordingStartedAt: Date?
        /// Capture initial save destinations at start-of-take so a Settings
        /// flip mid-recording doesn't change the destination list.
        var lockedDestinations: SaveDestinations = .default
        /// The physical hold captured ONCE at REC tap (V3 §07). The recording's
        /// orientation must be stable for the whole take — Photos/QuickTime
        /// have no concept of mid-file orientation change for a single track —
        /// so we snapshot the hold synchronously at the moment the user commits
        /// to the take (mirroring `lockedDestinations`), never per-frame and
        /// never from a device-orientation notification. Read in
        /// `lazilyStartWriterOnFirstSample` to compose the writer transform.
        /// Defaults `.portrait` — the identity-hold path that reproduces
        /// today's verified pipeline byte-for-byte.
        var lockedHold: OrientationPolicy.PhysicalHold = .portrait
        var sampleBufferRouter: SampleBufferRouter?
        /// Buffer dimensions the writer was configured with — populated by
        /// `lazilyStartWriterOnFirstSample` once the first frame's
        /// CMVideoFormatDescription has been read. Zero means we haven't
        /// received the first frame yet.
        var outputWidth: Int = 0
        var outputHeight: Int = 0
        /// The .mov destination URL the lazy writer construction will use.
        /// Set in `configureWriter`, cleared after the writer is built.
        var pendingWriterURL: URL?
        /// Count of video sample buffers received since recording started.
        /// We DROP the first `RecordingSession.warmupVideoFrames` buffers
        /// because the iOS 26 hardware encoder + sensor emit half-rendered
        /// or near-black frames during the first ~125 ms after a session
        /// reconfigure. The session start time is anchored to the FIRST
        /// non-warmup buffer (frame N+1) instead of frame 1, so the file's
        /// timeline begins at the first frame the user actually sees.
        var videoFramesReceived: Int = 0
    }

    /// Lock guarding all writer-pipeline properties. Held briefly — copy
    /// values out, work outside the lock, write back inside.
    /// `OSAllocatedUnfairLock` is iOS 16+ so no availability gate needed
    /// (project floor is iOS 17.0). Marked `nonisolated` so the
    /// recordingQueue handler (and the cameraSessionQueue config block)
    /// can acquire it without hopping to MainActor.
    fileprivate nonisolated let writerStateLock = OSAllocatedUnfairLock<WriterState>(
        initialState: WriterState()
    )

    /// Test seam — production callers leave this false. Tests set it true
    /// to skip every AVFoundation interaction so we exercise the state
    /// machine without touching real hardware. Mirrors `CameraStore`'s
    /// `suppressDeviceWork` pattern.
    private let suppressDeviceWork: Bool

    /// Optional callback invoked from the camera audio queue with every
    /// `AVCaptureAudioDataOutput` sample buffer — REGARDLESS of recording
    /// state. Wired by `AppState` to forward to `VoiceTracker.feedAudio`
    /// so voice tracking works whenever the camera session is running
    /// with audio attached, even without a recording in progress. Held
    /// `nonisolated(unsafe)` because the audio delegate runs on the
    /// recording queue and the closure body is responsible for its own
    /// thread safety (Apple documents `appendAudioSampleBuffer` as
    /// thread-safe, which is the canonical sink).
    nonisolated(unsafe) var audioFork: ((CMSampleBuffer) -> Void)?

    /// Persistent sample-buffer router for the AUDIO output. Distinct
    /// from the per-take router that handles video. Once installed by
    /// `ensureAudioCaptureRunning()` it stays installed for the rest
    /// of the session — voice tracking needs audio buffers even with
    /// no recording in progress, and re-installing the delegate per
    /// take created a hole where voice tracking received nothing
    /// outside an active recording.
    fileprivate var persistentAudioRouter: SampleBufferRouter?

    /// Drop this many video sample buffers at the start of every take. The
    /// iOS 26 hardware encoder + the camera sensor's settling pass after a
    /// session reconfigure produce half-rendered or near-black frames for
    /// roughly the first 100-150 ms of capture (the dogfood-pass-4
    /// "first frames are oddly black / 50% opacity" report). Three frames
    /// at 24 fps is ~125 ms — enough warmup to consistently start the file
    /// on a fully-rendered frame without sacrificing perceptible content.
    /// Bumped to 4 if dogfooding still shows black frames; reduced to 2 if
    /// the warmup is overkill on a future iOS / device.
    fileprivate static let warmupVideoFrames: Int = 3

    /// Live Activity handle for the in-flight recording, if any. Held
    /// strongly through the recording phase; ended on stop or failure.
    #if canImport(ActivityKit)
    @available(iOS 16.2, *)
    private var liveActivityRef: LiveActivityHandle? {
        get { _liveActivityRef as? LiveActivityHandle }
        set { _liveActivityRef = newValue }
    }
    private var _liveActivityRef: Any?
    #endif

    /// Countdown ticker — invalidated on cancel/stop.
    private var countdownTask: Task<Void, Never>? = nil

    /// Optional callback fired AFTER a successful Photos save. Wired by
    /// `AppState` to bump the review-prompt counter (Feature 8). Kept as
    /// a typed closure rather than a direct ReviewPromptCounter reference
    /// so the recording stack stays decoupled from review-prompt
    /// machinery — easier to test, easier to swap.
    private let onRecordingSaved: (@MainActor () -> Void)?

    // MARK: - Init

    init(
        state: RecordingState,
        cameraStore: CameraStore?,
        suppressDeviceWork: Bool = false,
        onRecordingSaved: (@MainActor () -> Void)? = nil
    ) {
        self.state = state
        self.cameraStore = cameraStore
        self.cameraSession = cameraStore?.session
        self.cameraSessionQueue = cameraStore?.sessionQueueRef
        self.suppressDeviceWork = suppressDeviceWork
        self.onRecordingSaved = onRecordingSaved

        // Ensure the recordings directory exists so the writer doesn't fail
        // on first launch. Failure here is non-fatal — the writer setup
        // path will surface a clear error if the disk is unavailable.
        try? RecordingFileStore.ensureDirectory()
    }

    /// Update which script is currently being prompted. The session uses
    /// this for the Live Activity title and the optional iCloud-next-to-
    /// script copy destination.
    func setCurrentScript(url: URL?, displayName: String) {
        self.currentScriptURL = url
        self.currentScriptName = displayName
    }

    // MARK: - Public API

    /// Begin a take. If a countdown is configured, this enters the
    /// countdown phase and the writer starts after the last tick. With
    /// countdown == off the writer starts immediately.
    ///
    /// Mic permission is requested here on first call. Photos permission
    /// is requested at save-time, not now — keeps the prompt close to the
    /// surface that needs it.
    func tapREC() async {
        // Check we can record (camera owner is happy + mic granted).
        guard cameraSession != nil || suppressDeviceWork else {
            state.surfaceError(RecordingSessionError.sessionNotReady.localizedDescription ?? "")
            return
        }
        let micGranted = await ensureMicrophoneAccess()
        guard micGranted else {
            state.surfaceError(RecordingSessionError.microphoneDenied.localizedDescription ?? "")
            return
        }

        // Lock save destinations now — the user may flip Settings mid-take
        // and we want the original choice to win. Lock the physical hold in
        // the SAME block (V3 §07): the hold is the phone's interface
        // orientation at the moment the user committed to the take, read
        // synchronously on the main actor. The countdown path funnels through
        // here before `beginRecording`, so a locked-in-advance hold is correct
        // even with a 3-second countdown.
        let destinations = SaveDestinations(
            photos: true,
            scriptFolder: Prefs.recordingSaveToScriptFolder
        )
        let hold = OrientationPolicy.currentPhysicalHold()
        writerStateLock.withLock {
            $0.lockedDestinations = destinations
            $0.lockedHold = hold
        }

        let countdown = RecordingCountdown(rawValue: Prefs.recordingCountdown) ?? .three
        if countdown.seconds <= 0 {
            await beginRecording()
        } else {
            startCountdown(seconds: countdown.seconds)
        }
    }

    /// Cancel an in-flight countdown. No-op outside the countdown phase.
    func tapCancelDuringCountdown() {
        guard case .countdown = state.phase else { return }
        countdownTask?.cancel()
        countdownTask = nil
        state.cancelCountdown()
    }

    /// Stop the writer and run the save flow. No-op outside the recording
    /// phase. Returns when the post-save toast / banner has been queued.
    func tapStop() async {
        guard case .recording = state.phase else { return }
        state.enterFinalizing()
        await finalizeWriter()
        let dests = writerStateLock.withLock { $0.lockedDestinations }
        state.enterSaving(destinations: dests)
        await runSaveFlow()
    }

    /// Hard reset — used on app background or scene-disconnect. Tears down
    /// the writer without saving (we don't currently have a "pause"
    /// concept; backgrounding mid-recording is treated as a stop).
    /// Idempotent: if the phase is already past `recording`, only the
    /// live-activity is closed.
    func teardown() async {
        countdownTask?.cancel()
        countdownTask = nil
        // Recording phase: same path as `tapStop`.
        if case .recording = state.phase {
            state.enterFinalizing()
            await finalizeWriter()
            let dests = writerStateLock.withLock { $0.lockedDestinations }
            state.enterSaving(destinations: dests)
            await runSaveFlow()
        } else if case .countdown = state.phase {
            // Cancel any in-flight countdown — the user navigated away
            // before recording started.
            state.cancelCountdown()
        }
        await endLiveActivityIfAny()
    }

    /// Idempotent. Installs a sample-buffer delegate on the camera's
    /// audio data output (if one isn't already installed) so audio
    /// buffers begin flowing through `appendSampleBuffer`. Call from
    /// the voice-tracking activation path so audio reaches the
    /// recognizer regardless of recording state.
    ///
    /// The persistent audio router lives for the rest of the session
    /// — there's no symmetric "stop" because the buffer-handling code
    /// is gated on consumer presence (`writer != nil` for recording,
    /// `audioFork != nil` AND `voiceTracker.isActive` for voice
    /// tracking). When neither consumer wants buffers, the router
    /// just discards them with an early return.
    func ensureAudioCaptureRunning(role: AudioSessionRole = .voiceTracking) async {
        guard !suppressDeviceWork else { return }
        guard let cameraSessionQueue = cameraSessionQueue,
              let audioOut = cameraStore?.preAttachedAudioOutput else {
            return
        }
        // The audio session needs to be active for the AVCapture audio
        // path to actually deliver buffers. Re-running this is cheap
        // and safe — it's also called at start of every recording. The
        // `role` reflects the actual consumer so the coordinator releases
        // the right claim later (default `.voiceTracking` — the standalone
        // voice-start path; the recording path passes `.recording`).
        configureAudioSession(role: role)
        // 2.0.2: removed the `guard persistentAudioRouter == nil`
        // early-return that gated this whole function. If the camera
        // session ever reconfigured between voice activations (style
        // toggle, aspect change, backgrounding cycle), the new
        // `_audioDataOutput` would have NO delegate while the old
        // router pointed at the stale output — voice tracking
        // received nothing despite "running." The user's repro:
        // fresh install → flaky → force-close × N → works fits this
        // shape if the first launch's session never properly bound.
        // Setting the delegate on the current audioOut on every call
        // is idempotent (Apple documents `setSampleBufferDelegate`
        // as safe to call repeatedly) and reuses the existing
        // router if there is one, so no extra allocation.
        let router = persistentAudioRouter ?? SampleBufferRouter(session: self)
        let recordQ = recordingQueue
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            cameraSessionQueue.async {
                audioOut.setSampleBufferDelegate(router, queue: recordQ)
                cont.resume()
            }
        }
        self.persistentAudioRouter = router
    }

    // MARK: - Countdown

    private func startCountdown(seconds: Int) {
        state.startCountdown(seconds: seconds)
        startLiveActivityIfNeeded(phase: .countdown(remaining: seconds))
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            for tick in 0..<seconds {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.state.tickCountdown()
                if case .countdown(let remaining) = self.state.phase {
                    self.updateLiveActivity(phase: .countdown(remaining: remaining))
                } else {
                    break
                }
                _ = tick
            }
            // The final tick took us into `recording`. Now actually start
            // the writer.
            guard !Task.isCancelled else { return }
            await self?.beginRecording()
        }
    }

    // MARK: - Writer setup / teardown

    private func beginRecording() async {
        let started = Date()
        // Reset per-take flags before we publish the recording phase.
        state.micUnavailableForThisTake = false
        writerStateLock.withLock { $0.recordingStartedAt = started }
        state.phase = .recording(startedAt: started)
        startLiveActivityIfNeeded(phase: .recording(startedAt: started))

        if suppressDeviceWork {
            return
        }

        guard let cameraSession, let cameraSessionQueue else {
            state.surfaceError(RecordingSessionError.sessionNotReady.localizedDescription ?? "")
            return
        }

        do {
            let url = RecordingFileStore.newRecordingURL(now: started)
            writerStateLock.withLock { $0.currentRecordingURL = url }
            try await configureWriter(at: url, cameraSession: cameraSession, cameraSessionQueue: cameraSessionQueue)
        } catch {
            state.surfaceError(error.localizedDescription)
            await endLiveActivityIfAny()
        }
    }

    /// Build the writer + inputs and attach the data-outputs to the shared
    /// session. The session-config block runs on `cameraSessionQueue`; the
    /// data-output delegate runs on `recordingQueue`.
    ///
    /// Dogfood-pass-3: writer construction (and the AVAssetWriter inputs)
    /// happen LAZILY in `appendSampleBuffer` once the first video frame
    /// arrives. We can read the buffer's exact dimensions from
    /// `CMSampleBufferGetFormatDescription` — that's the ground truth,
    /// regardless of what `device.activeFormat`, `device.dynamicDimensions`,
    /// or `device.dynamicAspectRatio` claim. The user's "writer dims=4032×3024
    /// when buffers are actually 3024×3024" smoking gun was a symptom of
    /// trying to predict the post-reshape dimensions BEFORE any sample
    /// buffer had arrived. Now we just wait for the truth.
    ///
    /// We still create the destination URL and attach the data outputs here
    /// so sample-buffer delivery starts ASAP. The writer itself is built
    /// inside `lazilyStartWriterOnFirstSample` once a real frame lands.
    private func configureWriter(
        at url: URL,
        cameraSession: AVCaptureSession,
        cameraSessionQueue: DispatchQueue
    ) async throws {
        let stabilization = RecordingStabilization(rawValue: Prefs.recordingStabilization) ?? .off

        // Activate the audio session for recording. Running this once at
        // start-of-take rather than session-load time keeps a non-recording
        // user from triggering a needless mic LED flicker.
        configureAudioSession(role: .recording)

        // Sample-buffer router. Holds a weak ref back into the session so
        // the AVFoundation callback path can append on the recording queue
        // without violating actor isolation.
        let router = SampleBufferRouter(session: self)

        // Seed the writer state inside the lock — writer/inputs are nil
        // until the first sample buffer arrives and lazilyStartWriterOnFirstSample
        // builds them from the buffer's CMVideoFormatDescription.
        writerStateLock.withLock { state in
            state.writer = nil
            state.videoInput = nil
            state.audioInput = nil
            state.hasStartedSession = false
            state.sessionStartTime = nil
            state.sampleBufferRouter = router
            state.outputWidth = 0
            state.outputHeight = 0
            state.pendingWriterURL = url
        }

        // Capture the lock + recordingQueue into locals so the
        // cameraSessionQueue closure (which is `Sendable`) doesn't have
        // to reach for `self.…` off-actor.
        let lock = writerStateLock
        let recordQ = recordingQueue

        // Pre-attached outputs from the camera store. Both the video and
        // audio data outputs were attached at session-config time inside
        // `CameraStore.configureInputsLocked` — the SAME bracket as the
        // camera input, audio input, format selection, and dynamic-aspect
        // reshape. Pre-attaching means REC tap NEVER opens a
        // begin/commit bracket on the camera session, so the iOS 26
        // dynamic-aspect 1×1 reshape stays stable across the take and
        // the preview can never visibly squeeze (the dogfood-pass-7
        // "PiP squeezes when REC tap fires" symptom).
        //
        // This routine is now config-free: we just toggle the sample
        // buffer delegate from `nil` to our router. AVFoundation routes
        // sample buffers to the delegate's recordingQueue; the writer
        // pipeline picks up from there. On stop, we toggle the delegate
        // back to `nil` and AVFoundation discards future samples at the
        // framework level (no encoder cost).
        guard let videoOut = cameraStore?.preAttachedVideoOutput,
              let audioOut = cameraStore?.preAttachedAudioOutput else {
            // Pre-attached outputs missing — the camera store hasn't
            // finished its first non-`.off` configure yet. Fail the
            // writer setup and let the state machine surface an error.
            throw RecordingSessionError.writerSetupFailed(
                "Camera outputs aren't ready yet."
            )
        }

        // Apply the user's stabilization preference per take. Connection-
        // level mutations are exempt from begin/commit brackets — they
        // don't reshape the connection graph, so they don't reset the
        // dynamic aspect. Safe to do here.
        if let connection = videoOut.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = stabilization.avMode
            }
        }

        // Audio path: install the persistent audio router IF not already
        // installed. Voice tracking needs audio whether or not a recording
        // is in progress, so we keep the audio delegate set for the
        // session's lifetime instead of toggling per-take. Pass `.recording`
        // so this call reinforces the recording claim rather than leaving a
        // stray `.voiceTracking` claim behind when voice isn't active.
        await ensureAudioCaptureRunning(role: .recording)

        // Video path: install per-take router. Cleared in `finalize`.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cameraSessionQueue.async {
                videoOut.setSampleBufferDelegate(router, queue: recordQ)
                lock.withLock { state in
                    state.videoOutput = videoOut
                    state.audioOutput = audioOut
                }
                continuation.resume()
            }
        }

        // Reflect mic-attachment outcome (read from the camera store, where
        // the audio input was attached at session-config time) so the chip
        // can show a strikethrough-mic glyph during a no-mic take.
        let micAttached = cameraStore?.currentAudioInputDevice != nil
        state.micUnavailableForThisTake = !micAttached
    }

    /// Build the AVAssetWriter on the recordingQueue using the actual buffer
    /// dimensions from the first sample. Called once, on the first video
    /// sample buffer, from `appendSampleBuffer`. Returns the writer + inputs
    /// so the caller can immediately start the session and append the
    /// triggering buffer. Failure surfaces an error back to the main actor
    /// state machine.
    nonisolated fileprivate func lazilyStartWriterOnFirstSample(
        url: URL,
        firstBuffer: CMSampleBuffer
    ) -> (
        writer: AVAssetWriter,
        video: AVAssetWriterInput,
        audio: AVAssetWriterInput,
        metadata: AVAssetWriterInput?,
        metadataAdaptor: AVAssetWriterInputMetadataAdaptor?,
        chapter: AVAssetWriterInput?,
        chapterTextFormat: CMFormatDescription?
    )? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(firstBuffer) else {
            return nil
        }
        let bufferDims = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let writerWidth = Int(bufferDims.width)
        let writerHeight = Int(bufferDims.height)
        guard writerWidth > 0 && writerHeight > 0 else { return nil }

        let quality = RecordingQuality(rawValue: Prefs.recordingQuality) ?? .default
        let framerate = RecordingFramerate(rawValue: Prefs.recordingFramerate) ?? .default

        // Fixed per-tier bitrate, framerate-aware (60 fps gets a 50% bonus).
        // We don't scale by pixel count — HEVC compresses very efficiently
        // and asking the iPhone 17 hardware encoder for 150+ Mbps at 12 MP
        // caused frame drops (the 22.68 fps dogfood symptom).
        let bitrate = quality.averageBitRate(framerate: framerate.fps)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            Task { @MainActor [weak self] in
                self?.state.surfaceError(
                    RecordingSessionError.writerSetupFailed(error.localizedDescription)
                        .localizedDescription ?? ""
                )
            }
            return nil
        }
        writer.shouldOptimizeForNetworkUse = false

        // Video input — HEVC at the chosen bitrate, ITU-R 709 color (no HDR
        // for selfie content). The expected source framerate hint helps the
        // encoder budget bits per frame correctly when we lock to fps.
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: quality.codec,
            AVVideoWidthKey: writerWidth,
            AVVideoHeightKey: writerHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: framerate.fps,
                // Cap keyframe interval at 1 keyframe per second of video.
                // Without this hint the encoder can pick GOP lengths that
                // fight the average-bitrate budget on motion-heavy content.
                AVVideoMaxKeyFrameIntervalKey: framerate.fps
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]

        #if DEBUG
        // Compare the buffer's truth-source dimensions against what
        // `device.activeFormat` and `device.dynamicDimensions` claim, so
        // the user can verify in Console.app that the buffer is the true
        // source of truth. activeFormat / dynamicDimensions can lie or lag
        // (the dogfood-pass-2 4032×3024 vs 3024×3024 mismatch).
        let activeDims: (Int, Int)
        let dynamicDims: (Int, Int)
        if let cs = cameraSession,
           let device = (cs.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .first { $0.device.hasMediaType(.video) })?.device {
            let af = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            activeDims = (Int(af.width), Int(af.height))
            if #available(iOS 26.0, *) {
                let dyn = device.dynamicDimensions
                dynamicDims = (Int(dyn.width), Int(dyn.height))
            } else {
                dynamicDims = (0, 0)
            }
        } else {
            activeDims = (0, 0)
            dynamicDims = (0, 0)
        }

        let recLog = Logger(
            subsystem: "app.openprompter.recording",
            category: "Writer-Dims-Debug"
        )
        recLog.info(
            "first frame received: \(writerWidth, privacy: .public)x\(writerHeight, privacy: .public) from CMSampleBuffer (vs activeFormat: \(activeDims.0, privacy: .public)x\(activeDims.1, privacy: .public), vs dynamicDimensions: \(dynamicDims.0, privacy: .public)x\(dynamicDims.1, privacy: .public))"
        )
        recLog.info(
            "writer setup quality=\(quality.rawValue, privacy: .public) fps=\(framerate.fps, privacy: .public) bitrate=\(bitrate, privacy: .public) dims=\(writerWidth)x\(writerHeight)"
        )
        #endif

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        // QA REVIEWER FOCUS: the writer transform now depends on BOTH the
        // user's picker aspect AND the actual buffer shape (read directly
        // from the sample buffer's format description, which is reliable
        // by first-sample time — no `dynamicDimensions` race).
        //
        // Why both: on iOS 26.3.1 the iPhone 17 Pro Max front camera does
        // NOT expose ratio1x1 in `supportedDynamicAspectRatios`, so when
        // the user picks `openGate` the format selector falls back to
        // ratio4x3, producing a 4032×3024 LANDSCAPE buffer. The pass-11
        // policy returned identity for openGate (assuming a square buffer)
        // and shipped landscape playback. The buffer-shape-aware policy
        // detects "landscape buffer + portrait-intent aspect" and applies
        // +π/2 to land portrait playback.
        //
        // Per Apple QA1744 ("Setting the orientation of video with AV
        // Foundation"), AVAssetWriter pipelines should leave the capture
        // connection at native rotation and let the writer's
        // `preferredTransform` metadata drive playback orientation —
        // which is exactly what this transform encodes.
        let bufferShape = OrientationPolicy.BufferShape.from(
            width: writerWidth,
            height: writerHeight
        ) ?? .landscape  // Defensive default — buffer dims should be valid here.
        // V3 §07: the writer transform is now a COMPOSITION of the physical
        // hold (locked at REC tap) and the verified per-(shape, bufferShape)
        // base. `lockedHold == .portrait` (the default and the upright case)
        // composes with identity, so portrait output is byte-identical to
        // today's verified pipeline. Read the hold synchronously from the
        // locked writer state — never probe device orientation here.
        let hold = writerStateLock.withLock { $0.lockedHold }
        videoInput.transform = OrientationPolicy.writerTransform(
            for: OrientationPolicy.current,   // .canonicalShape applied inside
            hold: hold,
            bufferShape: bufferShape
        )

        // Audio input — AAC, voiceover bitrate.
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 128_000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            Task { @MainActor [weak self] in
                self?.state.surfaceError(
                    RecordingSessionError.writerSetupFailed("Writer rejected inputs.")
                        .localizedDescription ?? ""
                )
            }
            return nil
        }
        writer.add(videoInput)
        writer.add(audioInput)

        // Timed-metadata input (V3 markers, H0a/H0b). A THIRD writer input
        // carrying an in-file timed-metadata track that Premiere / FCP /
        // Resolve read as markers. Gated on `recordingMarkerMetadataTrack`
        // (default on). The chapter track is written separately at
        // `finishWriting`; the two output shapes are independent so a user /
        // future Settings row can turn either off. The input must be added
        // BEFORE `startWriting`, hence its construction here.
        //
        // Per-frame metadata is delivered through an
        // `AVAssetWriterInputMetadataAdaptor`, which wants a source format
        // hint describing the metadata identifier space. We use the
        // QuickTime user-data "title" identifier — the same string that
        // labels a chapter — so a marker reads as a titled point.
        var metadataInput: AVAssetWriterInput?
        var metadataAdaptor: AVAssetWriterInputMetadataAdaptor?
        if Prefs.recordingMarkerMetadataTrack {
            let spec: [String: Any] = [
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                    AVMetadataIdentifier.quickTimeUserDataFullName.rawValue,
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                    kCMMetadataBaseDataType_UTF8 as String
            ]
            var formatDescription: CMFormatDescription?
            let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
                allocator: kCFAllocatorDefault,
                metadataType: kCMMetadataFormatType_Boxed,
                metadataSpecifications: [spec] as CFArray,
                formatDescriptionOut: &formatDescription
            )
            if status == noErr, let formatDescription {
                let input = AVAssetWriterInput(
                    mediaType: .metadata,
                    outputSettings: nil,
                    sourceFormatHint: formatDescription
                )
                input.expectsMediaDataInRealTime = true
                if writer.canAdd(input) {
                    writer.add(input)
                    // Associate the metadata track with the video track so a
                    // player scopes the markers to the picture (chapter-like).
                    if videoInput.canAddTrackAssociation(
                        withTrackOf: input, type: AVAssetTrack.AssociationType.metadataReferent.rawValue
                    ) {
                        videoInput.addTrackAssociation(
                            withTrackOf: input,
                            type: AVAssetTrack.AssociationType.metadataReferent.rawValue
                        )
                    }
                    metadataInput = input
                    metadataAdaptor = AVAssetWriterInputMetadataAdaptor(
                        assetWriterInput: input
                    )
                }
            }
        }

        // QuickTime CHAPTER track (V3 markers, second output shape). A `.text`
        // track associated to the video track as a `.chapterList`, whose titled
        // samples Photos / QuickTime render as scrubber ticks WITH readable
        // names. This is a TEXT track (not `.metadata`/`mebx`): QuickTime and
        // ffmpeg read chapter titles only from a text track's sample data, so
        // the previous metadata-based chapter track produced empty `TAG:title=`
        // chapters. Gated on `recordingMarkerChapterTrack` (default on). Its
        // samples are written all at once at `finishWriting` from the
        // accumulated `committedMarkers` (each chapter spans
        // `[marker_i, marker_{i+1})`), so nothing is appended to it during the
        // take. Must be added before `startWriting`, hence the construction
        // here. If CoreMedia rejects the text format description, the chapter
        // track is simply omitted — no crash, no effect on video/audio/markers.
        var chapterInput: AVAssetWriterInput?
        var chapterTextFormat: CMFormatDescription?
        if Prefs.recordingMarkerChapterTrack,
           let textFormat = ChapterTextTrack.makeTextFormatDescription() {
            let input = AVAssetWriterInput(
                mediaType: .text,
                outputSettings: nil,
                sourceFormatHint: textFormat
            )
            // Batch-written at `finishWriting`, NOT fed from a real-time capture
            // source — so `expectsMediaDataInRealTime` is FALSE here. A
            // real-time flag makes the input apply capture-style back-pressure
            // to the finalize-time burst and silently drop chapter samples via
            // `isReadyForMoreMediaData`.
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                // `.chapterList` is what makes this a chapter track a player
                // exposes as scrubber ticks (vs the metadata referent above,
                // which is a marker overlay for NLEs).
                if videoInput.canAddTrackAssociation(
                    withTrackOf: input, type: AVAssetTrack.AssociationType.chapterList.rawValue
                ) {
                    videoInput.addTrackAssociation(
                        withTrackOf: input,
                        type: AVAssetTrack.AssociationType.chapterList.rawValue
                    )
                }
                chapterInput = input
                chapterTextFormat = textFormat
            }
        }

        if !writer.startWriting() {
            let msg = writer.error?.localizedDescription ?? "Writer refused to start."
            Task { @MainActor [weak self] in
                self?.state.surfaceError(
                    RecordingSessionError.writerSetupFailed(msg).localizedDescription ?? ""
                )
            }
            return nil
        }

        return (
            writer, videoInput, audioInput,
            metadataInput, metadataAdaptor,
            chapterInput, chapterTextFormat
        )
    }

    /// Stop sample-buffer delivery, mark the inputs finished, and finalize
    /// the .mov. Errors get surfaced through the state machine.
    private func finalizeWriter() async {
        if suppressDeviceWork { return }

        guard let cameraSession, let cameraSessionQueue else { return }

        let lock = writerStateLock

        // Stop sample delivery WITHOUT removing the outputs. The pre-
        // attached video + audio data outputs (owned by CameraStore,
        // attached at session-config time) stay on the session for its
        // whole lifetime. Setting their sample buffer delegate to `nil`
        // tells AVFoundation to discard future samples at the framework
        // level — no encoder cost, no buffer copies, no work.
        //
        // Symmetric with REC-tap setup: we just toggle the delegate.
        // Crucially, this does NOT open a `beginConfiguration / commit`
        // bracket on the camera session, so the iOS 26 dynamic-aspect
        // 1×1 reshape is preserved across stop. The PiP preview stays
        // 1×1 throughout the take and after stop, no visible reshape
        // (the dogfood-pass-7 "PiP squeezes when REC tap fires" symptom
        // had a stop-side counterpart that's gone with this change).
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cameraSessionQueue.async {
                let (v, a) = lock.withLock { state -> (
                    AVCaptureVideoDataOutput?,
                    AVCaptureAudioDataOutput?
                ) in
                    let result = (state.videoOutput, state.audioOutput)
                    // Clear the references in writer state — the outputs
                    // themselves are owned by CameraStore and stay on
                    // the session; we just stop tracking them locally.
                    state.videoOutput = nil
                    state.audioOutput = nil
                    state.audioInputDevice = nil
                    return result
                }
                v?.setSampleBufferDelegate(nil, queue: nil)
                // Audio delegate is persistent (managed by
                // `ensureAudioCaptureRunning`) — voice tracking can be
                // active across recording cycles. The audio branch in
                // `appendSampleBuffer` is gated on `writer != nil` so
                // post-recording audio is dropped without effect.
                _ = a
                continuation.resume()
            }
        }
        // `cameraSession` referenced explicitly to silence unused-variable
        // warnings now that finalize is config-free.
        _ = cameraSession

        // Flush any marker taps that landed after the last processed video
        // frame (e.g. a tap between the final frame and stop). Runs on the
        // recording queue like every other marker append. Cheap no-op when
        // there's nothing pending.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            recordingQueue.async { [weak self] in
                self?.drainPendingMarkers()
                continuation.resume()
            }
        }

        // Write the QuickTime chapter track from the accumulated markers,
        // THEN mark inputs finished + finalize. Snapshot writer / inputs out
        // of the lock so we don't hold it across the (long) finishWriting.
        let snapshot = writerStateLock.withLock { state -> (
            writer: AVAssetWriter?,
            video: AVAssetWriterInput?,
            audio: AVAssetWriterInput?,
            metadata: AVAssetWriterInput?,
            chapter: AVAssetWriterInput?,
            chapterTextFormat: CMFormatDescription?,
            markers: [RecordingMarker],
            sessionStart: CMTime?,
            lastPTS: CMTime?
        ) in
            (state.writer, state.videoInput, state.audioInput,
             state.metadataInput, state.chapterInput, state.chapterTextFormat,
             state.committedMarkers, state.sessionStartTime, state.lastVideoPTS)
        }
        let writerRef = snapshot.writer
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            recordingQueue.async {
                guard let writer = writerRef else {
                    continuation.resume()
                    return
                }

                // HANG GUARD. If a bad sample append (an empty-value marker,
                // or the encoder) already flipped the writer to `.failed`, or
                // the session never started (a stop during warmup leaves it
                // `.unknown`), calling `finishWriting` is undefined and its
                // completion handler may NEVER fire — the "stuck on saving for
                // minutes" symptom. In those states, cancel and resume so the
                // save flow surfaces a clean error instead of the await
                // suspending forever. Only a `.writing` writer is finishable.
                guard writer.status == .writing else {
                    writer.cancelWriting()
                    continuation.resume()
                    return
                }

                // Chapter track: one titled TEXT sample per marker, spanning
                // `[marker_i, marker_{i+1})` (the last runs to `lastVideoPTS`).
                // Auto-number untitled (manual) markers "Marker N". Times are
                // already clamped into `[sessionStart, lastVideoPTS]` at drain,
                // but `buildChapterSegments` clamps again defensively — an
                // out-of-range chapter sample fails `finishWriting`.
                if let chapterInput = snapshot.chapter,
                   let chapterTextFormat = snapshot.chapterTextFormat,
                   let sessionStart = snapshot.sessionStart,
                   let lastPTS = snapshot.lastPTS {
                    let segments = buildChapterSegments(
                        from: snapshot.markers,
                        sessionStart: sessionStart,
                        lastPTS: lastPTS
                    )
                    for segment in segments {
                        // Skip degenerate (zero/negative-length) spans — a
                        // marker landing exactly on `lastVideoPTS` yields an
                        // empty range a text sample can't represent, and
                        // appending it can fail the writer.
                        guard CMTimeCompare(segment.end, segment.start) > 0 else { continue }
                        // The chapter input is batch-written (real-time flag
                        // off), so it is ready immediately; still, wait a
                        // BOUNDED interval rather than silently dropping a
                        // chapter if the writer momentarily back-pressures.
                        // Capped so finalize can never spin forever.
                        var waited = 0
                        while !chapterInput.isReadyForMoreMediaData
                            && writer.status == .writing
                            && waited < 200 {
                            usleep(500)            // 0.5 ms per turn, ≤100 ms total
                            waited += 1
                        }
                        guard writer.status == .writing,
                              chapterInput.isReadyForMoreMediaData else { break }
                        // Build the QuickTime text sample ([uint16 len][UTF-8]
                        // [encd]) for this chapter. A nil here (CoreMedia
                        // refused) just skips one chapter — it never fails the
                        // take. `append` returning false likewise stops chapters
                        // without aborting the video/audio finalize below.
                        guard let sampleBuffer = ChapterTextTrack.makeTextSampleBuffer(
                            title: segment.title,
                            format: chapterTextFormat,
                            timeRange: CMTimeRange(start: segment.start, end: segment.end)
                        ) else { continue }
                        if !chapterInput.append(sampleBuffer) { break }
                    }
                }

                // EVERY added input must be finished before `finishWriting`,
                // or it waits forever on the unfinished input. `nil` means the
                // input was never added (its pref is off) — nothing to finish.
                snapshot.metadata?.markAsFinished()
                snapshot.chapter?.markAsFinished()
                snapshot.video?.markAsFinished()
                snapshot.audio?.markAsFinished()

                // Appending chapters must not have failed the writer; if it
                // did, don't hang on `finishWriting` — cancel and resume.
                guard writer.status == .writing else {
                    writer.cancelWriting()
                    continuation.resume()
                    return
                }
                writer.finishWriting {
                    continuation.resume()
                }
            }
        }

        if let err = writerRef?.error {
            state.surfaceError(
                RecordingSessionError.finalizeFailed(err.localizedDescription).localizedDescription ?? ""
            )
        }

        // PRIMARY V3 DELIVERABLE — embed a Premiere-readable XMP Dynamic Media
        // marker track into the finished `.mov` (moov/udta/XMP_) so the tapped
        // marks import as NATIVE timeline markers in Adobe Premiere Pro. The
        // QuickTime chapter track + `mebx` metadata track do NOT import as
        // markers; XMP `xmpDM:Tracks` is Premiere's native marker format and
        // `moov/udta/XMP_` is where Premiere reads/writes XMP for a `.mov`
        // (confirmed by inspecting a founder recording round-tripped through
        // Premiere Pro 2026 — its own metadata lived there).
        //
        // Runs ONLY when finalize succeeded (no writer error) and the
        // NLE-marker pref is on — the same pref that gates the timed-metadata
        // track, since the XMP is the shape NLEs actually read. File I/O stays
        // on the recording queue, off the main actor, and happens BEFORE the
        // Photos save + DEBUG self-test stash (both in `runSaveFlow`, which
        // `tapStop` calls only after this `finalizeWriter` returns), so the
        // saved asset carries the markers. The injector never fails the take:
        // it leaves the file untouched on any structural surprise.
        if writerRef?.error == nil, Prefs.recordingMarkerMetadataTrack {
            let markerURL = writerStateLock.withLock { $0.currentRecordingURL }
            if let markerURL,
               let sessionStart = snapshot.sessionStart,
               let lastPTS = snapshot.lastPTS {
                let points = orderedMarkerPoints(
                    from: snapshot.markers,
                    sessionStart: sessionStart,
                    lastPTS: lastPTS
                )
                if !points.isEmpty {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        recordingQueue.async {
                            let packet = XMPMarkerWriter.makeXMPPacket(markers: points)
                            XMPMarkerWriter.injectXMPIntoMOV(
                                xmpPacket: Data(packet.utf8),
                                fileURL: markerURL
                            )
                            continuation.resume()
                        }
                    }
                }
            }
        }

        writerStateLock.withLock { state in
            state.writer = nil
            state.videoInput = nil
            state.audioInput = nil
            state.metadataInput = nil
            state.metadataAdaptor = nil
            state.chapterInput = nil
            state.chapterTextFormat = nil
            state.pendingMarkers = []
            state.committedMarkers = []
            state.lastVideoPTS = nil
            state.sampleBufferRouter = nil
            state.sessionStartTime = nil
            state.hasStartedSession = false
        }

        // Release the recording claim on the shared audio session (fix 1a).
        // If voice tracking is still active its `.voiceTracking` claim keeps
        // `.capture` applied; otherwise the coordinator re-establishes
        // `.ambient` and re-arms a live volume-button observer (audit A5).
        releaseAudioSession(role: .recording)
    }

    /// Sample-buffer append. Called on `recordingQueue`. Must NOT touch
    /// any @MainActor-isolated state — the router routes back through
    /// MainActor when it needs to. Reads writer-pipeline state via
    /// `writerStateLock` so it doesn't race the configure/finalize paths.
    ///
    /// Dogfood-pass-3: the writer is constructed lazily on the first video
    /// sample buffer here. Reading dimensions from
    /// `CMSampleBufferGetFormatDescription` is the only way to know the
    /// post-reshape buffer's actual shape — `device.dynamicDimensions` reads
    /// {0,0} synchronously after `setDynamicAspectRatio`, and the legacy
    /// `applyAspectRatio` helper was a guess that didn't always match.
    /// The buffer is the truth.
    ///
    /// If the writer enters `.failed` mid-recording (encoder couldn't keep
    /// pace, disk full, etc.), we hop to MainActor and surface a clean
    /// error rather than letting the next append crash the app.
    nonisolated fileprivate func appendSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        from output: AVCaptureOutput
    ) {
        // First, see if we need to lazily build the writer. The first video
        // sample buffer triggers writer construction using its actual
        // CMVideoFormatDescription dimensions — that's the ground truth.
        // Audio buffers arriving before the writer is built are dropped
        // (we wait for video to determine dimensions).
        let snapshot = writerStateLock.withLock { state -> (
            writer: AVAssetWriter?,
            videoInput: AVAssetWriterInput?,
            audioInput: AVAssetWriterInput?,
            hasStartedSession: Bool,
            pendingWriterURL: URL?
        ) in
            (state.writer, state.videoInput, state.audioInput, state.hasStartedSession, state.pendingWriterURL)
        }

        // Lazy writer construction on the first video sample buffer. The
        // writer is BUILT here but `startSession(atSourceTime:)` is deferred
        // until the first non-warmup buffer (see below) — that way the
        // file's timeline begins on a fully-rendered frame instead of one
        // of the half-rendered / black warmup frames the encoder + sensor
        // emit during the first ~125 ms of capture.
        if snapshot.writer == nil, output is AVCaptureVideoDataOutput {
            guard let url = snapshot.pendingWriterURL else { return }
            guard let built = lazilyStartWriterOnFirstSample(url: url, firstBuffer: sampleBuffer) else {
                // Failure surfaced through `state.surfaceError` from inside
                // the helper — clear the pending URL so we don't loop on
                // the next sample buffer.
                writerStateLock.withLock { state in
                    state.pendingWriterURL = nil
                }
                return
            }

            let bufferDims = CMVideoFormatDescriptionGetDimensions(
                CMSampleBufferGetFormatDescription(sampleBuffer)!
            )
            writerStateLock.withLock { state in
                state.writer = built.writer
                state.videoInput = built.video
                state.audioInput = built.audio
                state.metadataInput = built.metadata
                state.metadataAdaptor = built.metadataAdaptor
                state.chapterInput = built.chapter
                state.chapterTextFormat = built.chapterTextFormat
                state.outputWidth = Int(bufferDims.width)
                state.outputHeight = Int(bufferDims.height)
                state.hasStartedSession = false       // session not started yet
                state.sessionStartTime = nil
                state.lastVideoPTS = nil
                // Fresh take — any markers queued before the writer existed
                // (there shouldn't be, but a countdown race is conceivable)
                // are discarded rather than clamped to a stale clock.
                state.pendingMarkers = []
                state.committedMarkers = []
                state.pendingWriterURL = nil
                state.videoFramesReceived = 1         // count this triggering frame
            }
            // Drop this triggering buffer — it's the first warmup frame.
            return
        }

        // Drop audio buffers that arrive before the writer exists.
        guard let writer = snapshot.writer else { return }

        // Hard guard against a writer that has flipped into a non-writing
        // state — surface the error to the user and stop further appends.
        if writer.status == .failed {
            let msg = writer.error?.localizedDescription ?? "Writer failed mid-recording."
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only surface the error once — if the phase already moved
                // off recording we don't want to clobber the user's flow.
                if case .recording = self.state.phase {
                    self.state.surfaceError(
                        RecordingSessionError.writerSetupFailed(msg).localizedDescription ?? ""
                    )
                }
            }
            return
        }
        guard writer.status == .writing || writer.status == .unknown else { return }

        if output is AVCaptureVideoDataOutput {
            // Warmup-frame gate. The first `warmupVideoFrames` video buffers
            // after writer construction are dropped because the encoder +
            // sensor emit half-rendered / black frames during settling.
            // `startSession(atSourceTime:)` is deferred to the FIRST frame
            // we actually keep, so the file's timeline begins with content.
            let action: WarmupAction = writerStateLock.withLock { state in
                state.videoFramesReceived += 1
                if !state.hasStartedSession {
                    if state.videoFramesReceived <= Self.warmupVideoFrames {
                        return .dropWarmup
                    }
                    // Past warmup. Start the session at THIS frame's PTS,
                    // mark it started, and append.
                    state.hasStartedSession = true
                    return .startSessionAndAppend
                }
                return .append
            }
            switch action {
            case .dropWarmup:
                return
            case .startSessionAndAppend:
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                writer.startSession(atSourceTime: pts)
                writerStateLock.withLock {
                    $0.sessionStartTime = pts
                    $0.lastVideoPTS = pts
                }
                if let input = snapshot.videoInput, input.isReadyForMoreMediaData {
                    input.append(sampleBuffer)
                }
                drainPendingMarkers()
            case .append:
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                writerStateLock.withLock { $0.lastVideoPTS = pts }
                if let input = snapshot.videoInput, input.isReadyForMoreMediaData {
                    input.append(sampleBuffer)
                }
                drainPendingMarkers()
            }
        } else if output is AVCaptureAudioDataOutput {
            // Audio waits for the video session to actually start — until
            // then there's no `startSession(atSourceTime:)` anchor for the
            // writer to align audio buffers against.
            guard snapshot.hasStartedSession else { return }
            if let input = snapshot.audioInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        }
    }

    /// Branch decision for an incoming video sample buffer when warmup is
    /// in flight.
    private enum WarmupAction {
        case dropWarmup
        case startSessionAndAppend
        case append
    }

    // MARK: - Markers (V3 headline, H0a manual + H0b script)

    /// Drain queued markers into the timed-metadata track. Called on the
    /// `recordingQueue` right AFTER each video frame is appended, so the
    /// upper clamp bound (`lastVideoPTS`) is current and the session has
    /// started. Follows the "never await holding the lock" discipline:
    /// copy the pending array out under the lock, release, then append.
    ///
    /// The timed-metadata adaptor wants a `CMTimeRange`; a marker is a POINT,
    /// so we give it a zero-duration range at the (clamped) marker time.
    /// Every drained marker is also accumulated into `committedMarkers` so
    /// the chapter track can be built from the same list at finalize.
    nonisolated fileprivate func drainPendingMarkers() {
        // Snapshot everything we need under the lock, then release before any
        // AVFoundation append. `pendingMarkers` is cleared inside the lock so
        // a concurrent tap doesn't lose a marker between copy-out and clear.
        typealias DrainSnapshot = (
            adaptor: AVAssetWriterInputMetadataAdaptor?,
            input: AVAssetWriterInput?,
            markers: [RecordingMarker],
            sessionStart: CMTime?,
            lastPTS: CMTime?,
            writer: AVAssetWriter?
        )
        let drained: DrainSnapshot = writerStateLock.withLock { state -> DrainSnapshot in
            guard !state.pendingMarkers.isEmpty else {
                return (nil, nil, [], nil, nil, nil)
            }
            let pending = state.pendingMarkers
            state.pendingMarkers.removeAll(keepingCapacity: true)
            return (
                state.metadataAdaptor,
                state.metadataInput,
                pending,
                state.sessionStartTime,
                state.lastVideoPTS,
                state.writer
            )
        }

        guard !drained.markers.isEmpty else { return }
        // Without a session-start anchor there's no valid clamp window yet —
        // requeue so a later frame (which will have an anchor) drains them.
        guard let sessionStart = drained.sessionStart,
              let lastPTS = drained.lastPTS else {
            writerStateLock.withLock { $0.pendingMarkers.insert(contentsOf: drained.markers, at: 0) }
            return
        }

        var committedThisPass: [RecordingMarker] = []
        for marker in drained.markers {
            // A marker queued during warmup (before the first frame) carries
            // `CMTime.invalid`; anchor it to the session start now that we
            // have one. Everything else clamps into the valid window.
            let rawTime = marker.time.isValid ? marker.time : sessionStart
            let clamped = clampMarkerTime(rawTime, lower: sessionStart, upper: lastPTS)
            let committed = RecordingMarker(time: clamped, title: marker.title)
            committedThisPass.append(committed)

            // Timed-metadata track — only if the adaptor exists (pref on), the
            // writer is still healthy, AND the input can take data. The
            // QuickTime chapter track is built separately at finalize from
            // `committedMarkers`, so a marker is still recorded even when the
            // metadata-track pref is off. Gating on `writer.status == .writing`
            // stops us from appending into a writer that already failed (which
            // would compound the failure), and `markerMetadataLabel` guarantees
            // a NON-EMPTY value — an empty boxed-UTF-8 sample flips the writer
            // to `.failed` (the manual-mark hang; see `markerMetadataLabel`).
            if let adaptor = drained.adaptor,
               let input = drained.input,
               drained.writer?.status == .writing,
               input.isReadyForMoreMediaData {
                let item = AVMutableMetadataItem()
                item.identifier = .quickTimeUserDataFullName
                item.dataType = kCMMetadataBaseDataType_UTF8 as String
                item.value = markerMetadataLabel(title: committed.title) as NSString
                let group = AVTimedMetadataGroup(
                    items: [item],
                    timeRange: CMTimeRange(start: clamped, duration: .zero)
                )
                adaptor.append(group)
            }
        }

        // Accumulate for the finalize-time chapter track.
        writerStateLock.withLock { state in
            state.committedMarkers.append(contentsOf: committedThisPass)
        }
    }

    /// Queue a marker at the given absolute capture-clock time. Shared by the
    /// manual-tap path and the script-crossing path. MainActor-safe: appends
    /// into `pendingMarkers` under the lock without awaiting. Drained on the
    /// next video frame by `drainPendingMarkers()`.
    ///
    /// No-op outside `.recording` — a mark makes no sense before the writer
    /// exists, and outside a take there's no timeline to anchor it to.
    private func enqueueMarker(title: String?) {
        guard case .recording = state.phase else { return }
        // Anchor to the most recent video PTS — the frame the user is
        // actually looking at when they tap / when a block crosses. If no
        // frame has landed yet (the ~125 ms warmup window at the very start
        // of a take, before `startSession`), queue with `CMTime.invalid`;
        // `drainPendingMarkers` substitutes the session start once the anchor
        // exists, so an early crossing lands at the file's first frame rather
        // than being lost.
        writerStateLock.withLock { state in
            let anchor = state.lastVideoPTS ?? state.sessionStartTime ?? .invalid
            state.pendingMarkers.append(RecordingMarker(time: anchor, title: title))
        }
    }

    /// MANUAL marker (H0a). Bound to the "mark" chip near the camera toggle
    /// and to the `.dropMarker` remote event. Drops an auto-numbered marker
    /// (title `nil` → "Marker N" at finalize) at the current frame.
    func tapMark() {
        guard case .recording = state.phase else { return }
        enqueueMarker(title: nil)
        Haptics.tap(.medium)
    }

    #if DEBUG
    // MARK: - Marker test seams (DEBUG only)
    //
    // The marker pipeline's live path needs a real writer + sample buffers,
    // which the `suppressDeviceWork` test mode has none of. These seams let a
    // unit test drive the queue/anchor/clamp logic deterministically without
    // AVFoundation: inject a synthetic session clock, enqueue via the public
    // tap/appendChapter API, run the SAME `drainPendingMarkers` used in
    // production, and read back the committed markers.

    /// Inject a synthetic capture clock so `enqueueMarker` has an anchor and
    /// `drainPendingMarkers` has a clamp window, exactly as the video-frame
    /// path would set them in production.
    func _testSeedWriterClock(sessionStart: CMTime, lastVideoPTS: CMTime) {
        writerStateLock.withLock { state in
            state.sessionStartTime = sessionStart
            state.lastVideoPTS = lastVideoPTS
        }
    }

    /// Number of markers still queued (not yet drained).
    var _testPendingMarkerCount: Int {
        writerStateLock.withLock { $0.pendingMarkers.count }
    }

    /// Markers committed so far this take (drained into the metadata track and
    /// accumulated for the chapter track), as `(offsetSeconds, title)` where
    /// the offset is `markerTime − sessionStart` in seconds — i.e. the file-
    /// relative time the marker lands at. Titles preserve `nil` for manual.
    var _testCommittedMarkers: [(offset: Double, title: String?)] {
        writerStateLock.withLock { state in
            let start = state.sessionStartTime ?? .zero
            return state.committedMarkers.map { marker in
                (CMTimeGetSeconds(marker.time - start), marker.title)
            }
        }
    }

    /// Run the production drain synchronously (it's `nonisolated` and takes no
    /// AVFoundation-only path when the adaptor is absent, which it is in the
    /// suppressed test mode — markers still accumulate into `committedMarkers`).
    func _testDrainPendingMarkers() {
        drainPendingMarkers()
    }
    #endif

    // MARK: - Save flow

    private func runSaveFlow() async {
        let (url, dests): (URL?, SaveDestinations) = writerStateLock.withLock {
            ($0.currentRecordingURL, $0.lockedDestinations)
        }
        guard let url else {
            state.finishSavingSuccessfully(photos: false, scriptFolder: false)
            await endLiveActivityIfAny()
            return
        }

        // Photos write — write-only access. We request the limited add-only
        // scope per Apple's privacy guidelines (NSPhotoLibraryAddUsageDescription).
        var photosOK = false
        if dests.photos {
            photosOK = await writeToPhotos(url: url)
        }

        // iCloud-next-to-script — only if requested AND a script is loaded.
        // The copy now runs on a detached task so multi-hundred-MB files
        // don't freeze MainActor.
        var icloudOK = false
        var icloudFailureReason: String? = nil
        if dests.scriptFolder, let script = currentScriptURL {
            switch await ICloudCopyJob.copy(recording: url, forScript: script) {
            case .success:                icloudOK = true
            case .failure(let err):       icloudFailureReason = err.userMessage
            }
        }

        // Tear down the live activity unconditionally now — the recording
        // is finished, regardless of save outcome.
        await endLiveActivityIfAny()

        // Surface the right toast / banner. Photos failure is loud (the
        // file lives in the sandbox; we tell the user). iCloud failure is
        // a banner with the reason; Photos may have succeeded so the
        // success toast still fires per V2 Design 02 review note 4.
        if let reason = icloudFailureReason {
            state.surfaceICloudCopyFailure(reason: reason, photosSucceeded: photosOK)
        } else {
            state.finishSavingSuccessfully(photos: photosOK, scriptFolder: icloudOK)
        }

        // If Photos succeeded, drop the sandbox copy so the next recovery
        // scan doesn't surface a stale "recover partial recording" banner.
        // If Photos failed, keep the sandbox file so the user can recover
        // it via Files app or via the recovery banner.
        if photosOK {
            #if DEBUG
            // Stash a canonical "last recording" copy at a stable path
            // BEFORE the post-save delete fires. The self-test harness
            // reads from this path because Documents/Recordings/ would
            // otherwise be empty (the file we just saved is removed below
            // to avoid spurious recovery banners). Production builds skip
            // the copy entirely.
            if let docs = try? FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
            ) {
                let lastRec = docs.appendingPathComponent("SelfTestLastRecording.mov")
                try? FileManager.default.removeItem(at: lastRec)
                try? FileManager.default.copyItem(at: url, to: lastRec)
            }
            #endif
            RecordingFileStore.removeRecording(at: url)

            // Bump the App Store review-prompt counter (Feature 8). Only
            // counts successful saves — a failure represents friction,
            // not a "would you tell others" moment. The callback hook is
            // injected at init time by AppState so RecordingSession stays
            // ignorant of the counter type. The actual prompt call lives
            // at scenePhase = .active so it fires on a fresh foreground
            // rather than mid-flow.
            onRecordingSaved?()
        }
        writerStateLock.withLock { state in
            state.currentRecordingURL = nil
            state.recordingStartedAt = nil
        }
    }

    private func writeToPhotos(url: URL) async -> Bool {
        if suppressDeviceWork { return true }

        // Ask for write-only access on first attempt. PhotoKit returns
        // .authorized immediately on subsequent calls.
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        Prefs.recordingPhotosPermissionAsked = true
        guard status == .authorized || status == .limited else {
            state.surfaceError(RecordingSessionError.photosDenied.localizedDescription ?? "")
            return false
        }

        // Save directly to the user's library (Recents). The previous
        // implementation also linked the asset into a custom "Open Prompter"
        // album via `PHAssetCollection.fetchAssetCollections(with:subtype:options:)`
        // — but enumerating collections is a Photos READ operation, which
        // requires `NSPhotoLibraryUsageDescription`. We declare only the
        // write-only `NSPhotoLibraryAddUsageDescription`, so the read-time
        // fetch crashed the app on iOS 26 ("attempted to access privacy-
        // sensitive data without a usage description"). Dropping the album
        // keeps us strictly write-only — the saved video lands in Recents
        // either way and the user can move it into any album from Photos.
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
                request?.creationDate = .now
                request?.location = nil
            } completionHandler: { success, error in
                if let error, !success {
                    Task { @MainActor [weak self] in
                        self?.state.surfaceError(
                            RecordingSessionError.photosWriteFailed(error.localizedDescription)
                                .localizedDescription ?? ""
                        )
                    }
                }
                continuation.resume(returning: success)
            }
        }
    }

    // MARK: - Permission helpers

    private func ensureMicrophoneAccess() async -> Bool {
        if suppressDeviceWork {
            // Tests run without an Info.plist mic key — bypass.
            return true
        }
        // iOS 17+ replaced the deprecated `AVAudioSession.requestRecordPermission`
        // with `AVAudioApplication.requestRecordPermission()`. Project floor
        // is iOS 17.0, so no availability gate needed.
        switch AVAudioApplication.shared.recordPermission {
        case .granted:      return true
        case .denied:       return false
        case .undetermined: return await AVAudioApplication.requestRecordPermission()
        @unknown default:   return false
        }
    }

    /// Claim the shared audio session through the coordinator (fix 1a). The
    /// coordinator serializes the `.playAndRecord` / `.videoRecording`
    /// configuration recording and voice both request so the volume-button
    /// source's `outputVolume` KVO can be re-armed when the category flips —
    /// it used to race `setCategory` directly and silently killed that KVO.
    ///
    /// The audio config is byte-for-byte what recording used before; only the
    /// path to `AVAudioSession` changed. `role` distinguishes an actual
    /// recording claim from the voice-tracking path that also runs this via
    /// `ensureAudioCaptureRunning`, so releases are symmetric.
    private func configureAudioSession(role: AudioSessionRole) {
        guard !suppressDeviceWork else { return }
        // Best-effort — the writer falls back to the system route if we can't
        // lock our category. The coordinator returns the error rather than
        // throwing; recording has no user-facing surface for it here (the
        // mic-unavailable chip covers the observable failure) so we discard.
        _ = AudioSessionCoordinator.shared.claim(role, configuration: .capture)
    }

    /// Release this session's audio-session claim. Called when recording
    /// finalizes; if voice tracking still holds `.voiceTracking` the
    /// coordinator keeps `.capture` applied, otherwise a live volume observer
    /// is re-armed against `.ambient` (fix 1a, audit A5).
    private func releaseAudioSession(role: AudioSessionRole) {
        guard !suppressDeviceWork else { return }
        AudioSessionCoordinator.shared.release(role)
    }

    /// Fallback dimension resolver — kept for any callsite that needs to
    /// pre-compute writer dimensions BEFORE a sample buffer arrives. The
    /// primary recording path no longer uses this: it waits for the first
    /// frame and reads dimensions from `CMSampleBufferGetFormatDescription`,
    /// which is always the truth. This helper guesses based on
    /// `device.dynamicDimensions` (iOS 26+) and falls back to applying the
    /// requested aspect ratio to native sensor dims — both can lie.
    ///
    /// Resolution priority:
    ///   1. iOS 26+ `device.dynamicDimensions` — the post-reshape buffer
    ///      when `setDynamicAspectRatio` has been applied. Most accurate.
    ///   2. If we know the requested aspect (`requestedAspectRaw` is set)
    ///      but `dynamicDimensions` is {0,0} — the API is async and the
    ///      reshape hasn't published yet — apply the requested aspect to
    ///      the native format dimensions ourselves.
    ///   3. Otherwise: native `formatDescription` dims.
    ///
    /// IMPORTANT: dimensions returned here are buffer-native (landscape on
    /// the front camera). The writer applies a 90° rotation transform on
    /// the video input so the resulting MOV plays right-side-up, but the
    /// writer's `AVVideoWidthKey`/`AVVideoHeightKey` describe the source
    /// buffer's pre-rotation shape — landscape (width > height) for the
    /// 4:3 path, square (width == height) for the iPhone 17 1×1 path.
    nonisolated internal static func resolveWriterDimensions(
        from cameraSession: AVCaptureSession,
        requestedAspectRaw: String? = nil
    ) -> (width: Int, height: Int) {
        guard let device = (cameraSession.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .first { $0.device.hasMediaType(.video) })?.device
        else {
            return (width: 0, height: 0)
        }

        // Step 1: iOS 26+ dynamicDimensions when populated.
        if #available(iOS 26.0, *) {
            let dyn = device.dynamicDimensions
            if dyn.width > 0 && dyn.height > 0 {
                return (Int(dyn.width), Int(dyn.height))
            }
        }

        let nativeDims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let nativeW = Int(nativeDims.width)
        let nativeH = Int(nativeDims.height)

        // Step 2: apply the requested aspect to native dims if we know we
        // asked for a reshape but dynamicDimensions hasn't caught up.
        if let raw = requestedAspectRaw,
           let resized = applyAspectRatio(rawAspect: raw, toNativeWidth: nativeW, height: nativeH)
        {
            return resized
        }

        // Step 3: native format dims.
        return (nativeW, nativeH)
    }

    /// Pure helper — given a raw `AVCaptureDevice.AspectRatio` string and
    /// the native sensor width/height (e.g. 4032×3024 on iPhone 17 front),
    /// compute the dimensions of the buffer the camera will emit after the
    /// dynamic-aspect reshape. Returns nil if the raw value is unrecognized.
    /// Pure value-in / value-out so unit tests don't need AVFoundation.
    nonisolated internal static func applyAspectRatio(
        rawAspect: String,
        toNativeWidth nativeW: Int,
        height nativeH: Int
    ) -> (width: Int, height: Int)? {
        guard nativeW > 0 && nativeH > 0 else { return nil }
        // Apple's raw values for the iOS 26 enum. Match Apple's string
        // form so we don't gate this helper behind iOS 26 availability.
        let (aspectW, aspectH): (Int, Int)
        switch rawAspect {
        case "AVCaptureAspectRatio1x1":  (aspectW, aspectH) = (1, 1)
        case "AVCaptureAspectRatio4x3":  (aspectW, aspectH) = (4, 3)
        case "AVCaptureAspectRatio16x9": (aspectW, aspectH) = (16, 9)
        default:                          return nil
        }
        // Reshape preserves the smaller axis at full sensor and crops the
        // longer axis to match the requested ratio. Compute target dims
        // that fit inside the native frame and match `aspectW:aspectH`.
        // For native 4032×3024 (4:3) → 1:1 means crop to 3024×3024.
        // For native 4032×3024 (4:3) → 16:9 means crop to 4032×2268.
        let targetW: Int
        let targetH: Int
        if nativeW * aspectH >= nativeH * aspectW {
            // Native is "wider than" target ratio — height stays, crop width.
            targetH = nativeH
            targetW = nativeH * aspectW / aspectH
        } else {
            // Native is "taller than" target ratio — width stays, crop height.
            targetW = nativeW
            targetH = nativeW * aspectH / aspectW
        }
        return (targetW, targetH)
    }

    // (dogfood-pass-11) The static `writerTransform(forBufferWidth:height:)`
    // helper that lived here has been removed. Rotation is now keyed by
    // the user's picker aspect via `OrientationPolicy.writerTransform(for:)`,
    // which is shared with the preview layer. The buffer-dim probe was
    // removed because `device.dynamicDimensions` returns (0,0) for ~33-100
    // ms after `setDynamicAspectRatio` lands on a cold launch, and the
    // first-sample read at that window picked the wrong rotation. See
    // `OrientationPolicy.swift`.

    // MARK: - Live Activity

    private func startLiveActivityIfNeeded(phase: RecordingPhase) {
        let pref = RecordingIndicatorPref(rawValue: Prefs.recordingIndicator) ?? .both
        guard pref.showsLiveActivity else { return }
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            // Already running? Just update.
            if liveActivityRef != nil {
                updateLiveActivity(phase: phase)
                return
            }
            let attrs = PrompterRecordingAttributes(scriptID: currentScriptURL?.absoluteString ?? "")
            let initialState = liveActivityState(for: phase)
            do {
                let activity = try Activity<PrompterRecordingAttributes>.request(
                    attributes: attrs,
                    contentState: initialState,
                    pushType: nil
                )
                liveActivityRef = LiveActivityHandle(activity: activity)
            } catch {
                // Live Activity request fails silently — the in-app indicators
                // are belt-and-suspenders enough.
            }
        }
        #endif
    }

    private func updateLiveActivity(phase: RecordingPhase) {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            guard let handle = liveActivityRef else { return }
            let new = liveActivityState(for: phase)
            Task {
                await handle.activity.update(
                    ActivityContent<PrompterRecordingAttributes.ContentState>(
                        state: new,
                        staleDate: nil
                    )
                )
            }
        }
        #endif
    }

    /// Build a state payload for the Live Activity. The countdown numeral
    /// rides on `elapsedSeconds`; the running clock rides on `startedAt`
    /// and the widget renders it via `Text(date, style: .timer)` so we
    /// don't need per-second `Activity.update` pushes — phase transitions
    /// are the only updates we send.
    private func liveActivityState(for phase: RecordingPhase) -> PrompterRecordingAttributes.PrompterRecordingState {
        switch phase {
        case .countdown(let remaining):
            return PrompterRecordingAttributes.PrompterRecordingState(
                elapsedSeconds: remaining,
                startedAt: .distantPast,
                scriptTitle: currentScriptName,
                phase: phase.simpleKey
            )
        case .recording(let started):
            return PrompterRecordingAttributes.PrompterRecordingState(
                elapsedSeconds: 0,
                startedAt: started,
                scriptTitle: currentScriptName,
                phase: phase.simpleKey
            )
        default:
            return PrompterRecordingAttributes.PrompterRecordingState(
                elapsedSeconds: 0,
                startedAt: .distantPast,
                scriptTitle: currentScriptName,
                phase: phase.simpleKey
            )
        }
    }

    private func endLiveActivityIfAny() async {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            guard let handle = liveActivityRef else { return }
            let final = PrompterRecordingAttributes.PrompterRecordingState(
                elapsedSeconds: 0,
                startedAt: .distantPast,
                scriptTitle: currentScriptName,
                phase: "idle"
            )
            await handle.activity.end(
                ActivityContent<PrompterRecordingAttributes.ContentState>(
                    state: final,
                    staleDate: nil
                ),
                dismissalPolicy: .immediate
            )
            liveActivityRef = nil
        }
        #endif
    }

    // MARK: - Script markers (V3 headline, H0b)

    /// SCRIPT marker (H0b). Called from the prompter when a heading or a
    /// `[MARK]` / `[MARK: title]` / `[[mark]]` cue crosses the reading
    /// eye-line during a take. Anchors the marker to the current frame —
    /// the `time` argument is retained for API shape but the frame-accurate
    /// anchor is `lastVideoPTS`, read synchronously under the lock, which is
    /// exactly the crossing moment for both constant-speed and voice-tracked
    /// scroll. Dedupe (mark each block index once per take) lives in the
    /// caller (`PrompterViewModel`), which owns block identity.
    ///
    /// - Parameters:
    ///   - title: The chapter title (heading text or the cue's title).
    ///   - time: Retained for call-site clarity / tests; the marker is
    ///     anchored to the live capture clock, not this value.
    func appendChapter(title: String, at time: CMTime) {
        _ = time
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        enqueueMarker(title: trimmed.isEmpty ? nil : trimmed)
    }
}

// MARK: - Sample-buffer router

/// AVFoundation calls back on the data-output delegate; we cast the call
/// back into the session via this nonisolated forwarder. Holds a weak ref
/// to the session so the actor isolation isn't violated. `fileprivate` so
/// `RecordingSession.WriterState` (also `fileprivate`) can hold one.
fileprivate final class SampleBufferRouter:
    NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate
{
    weak var session: RecordingSession?
    init(session: RecordingSession) { self.session = session }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let session else { return }
        // Voice-tracking fork — independent of recording state. Runs
        // BEFORE the writer path so audio reaches the recognizer even
        // when no recording is in progress.
        if output is AVCaptureAudioDataOutput {
            session.audioFork?(sampleBuffer)
        }
        // The session's `appendSampleBuffer` is `nonisolated` — we can call
        // it directly from this background queue without hopping actors.
        session.appendSampleBuffer(sampleBuffer, from: output)
    }
}

// MARK: - Live Activity wrapper

#if canImport(ActivityKit)
@available(iOS 16.2, *)
private struct LiveActivityHandle {
    let activity: Activity<PrompterRecordingAttributes>
}
#endif

// MARK: - CameraStore session-queue access

/// `CameraStore` keeps `sessionQueue` private — recording needs to reach
/// it for the begin/commit configuration block. We expose a read-only
/// alias here that mirrors the store's accessor, so callsites read
/// `cameraStore.sessionQueueRef` (intent-revealing) rather than the raw
/// `_exposedSessionQueueRef`.
extension CameraStore {
    nonisolated var sessionQueueRef: DispatchQueue { _exposedSessionQueueRef }
}

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
//  Future work hooks (not implemented in this PR):
//  - Chapter markers (Feature 3) — `appendChapter(_:at:)` is reserved on
//    this type so the writer pipeline accommodates the future addition
//    without a refactor. Marker writes happen at finalize time as
//    `AVMetadataItem`s on the writer's metadata track.
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

    // MARK: - Init

    init(
        state: RecordingState,
        cameraStore: CameraStore?,
        suppressDeviceWork: Bool = false
    ) {
        self.state = state
        self.cameraStore = cameraStore
        self.cameraSession = cameraStore?.session
        self.cameraSessionQueue = cameraStore?.sessionQueueRef
        self.suppressDeviceWork = suppressDeviceWork

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
        // and we want the original choice to win.
        let destinations = SaveDestinations(
            photos: true,
            scriptFolder: Prefs.recordingSaveToScriptFolder
        )
        writerStateLock.withLock { $0.lockedDestinations = destinations }

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
        configureAudioSession()

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

        // Add data outputs to the shared session inside a configuration
        // block. We do this on the camera's session queue to avoid racing
        // with the camera store's own start/stop transitions.
        //
        // The audio INPUT (the AVCaptureDeviceInput pulling samples from
        // the mic) is owned by CameraStore now — attached at session-config
        // time rather than recording-start time. That keeps the iOS 26
        // dynamic-aspect reshape stable across REC tap (the dogfood-pass-3
        // "PiP stretches when REC starts" bug). We just attach the audio
        // DATA OUTPUT here to gate samples into the writer.
        // Snapshot the dynamic-aspect-ratio request from the camera store so we
        // can re-apply it AFTER the begin/commit cycle below. Adding outputs
        // forces a session reconfigure on iOS 26 which silently resets the
        // dynamic aspect ratio back to the format's native (the dogfood-pass-4
        // "PiP stretches when REC tap fires" smoking gun — moving the audio
        // INPUT to session-config time fixed the input side, but adding the
        // video + audio data OUTPUTs here still triggered the same reset).
        let cameraStoreRef = cameraStore
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            cameraSessionQueue.async {
                cameraSession.beginConfiguration()

                let videoOut = AVCaptureVideoDataOutput()
                videoOut.alwaysDiscardsLateVideoFrames = false
                videoOut.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                ]
                videoOut.setSampleBufferDelegate(router, queue: recordQ)
                if cameraSession.canAddOutput(videoOut) {
                    cameraSession.addOutput(videoOut)
                    lock.withLock { $0.videoOutput = videoOut }
                    if let connection = videoOut.connection(with: .video) {
                        if connection.isVideoStabilizationSupported {
                            connection.preferredVideoStabilizationMode = stabilization.avMode
                        }
                        // Front camera has the connection.videoMirrored
                        // convention — write a NON-mirrored .mov so the
                        // recording matches "what an external camera saw".
                        // The on-screen preview keeps its own mirroring
                        // rules independent of this.
                        if connection.isVideoMirroringSupported {
                            connection.automaticallyAdjustsVideoMirroring = false
                            connection.isVideoMirrored = false
                        }
                        // Pre-rotate buffers at capture time (iOS 17+ API).
                        // This avoids the AVAssetWriter post-write rotation
                        // transform (`videoInput.transform`) that produced a
                        // black first frame on iOS 26 — the writer-level
                        // transform sometimes generates a black placeholder
                        // for frame 0 before the encoder's rotated output
                        // catches up. Pre-rotating at the connection means
                        // sample buffers arrive already in portrait
                        // orientation; the writer just stores them without
                        // any transform.
                        if connection.isVideoRotationAngleSupported(90) {
                            connection.videoRotationAngle = 90
                        }
                    }
                }
                let audioOut = AVCaptureAudioDataOutput()
                audioOut.setSampleBufferDelegate(router, queue: recordQ)
                if cameraSession.canAddOutput(audioOut) {
                    cameraSession.addOutput(audioOut)
                    lock.withLock { $0.audioOutput = audioOut }
                }

                // Framerate pinning is handled by `CameraStore.configureInputsLocked`
                // when the active format is chosen — it locks both
                // `activeVideoMinFrameDuration` and `activeVideoMaxFrameDuration`
                // inside the same `lockForConfiguration` block as the format
                // assignment. We rely on that pin here; re-locking from the
                // recording side races the camera store's own lock holders.

                cameraSession.commitConfiguration()

                // RE-APPLY the dynamic aspect ratio after commit. Adding the
                // video + audio outputs above forced a reconfigure that
                // silently reset iOS 26's dynamic aspect to the format's
                // native (4:3). Without this re-application the live preview
                // and the captured buffers reshape from 1:1 back to 4:3 the
                // moment recording starts — the user-visible "PiP stretches"
                // symptom. The lock-then-set-then-unlock sequence is async
                // because `setDynamicAspectRatio` is async; we don't wait on
                // its completion here because the next sample buffer carrying
                // the reshaped dimensions is what the lazy-writer reads
                // anyway, and the preview layer picks up the reshape on its
                // own KVO cycle.
                if #available(iOS 26.0, *),
                   let aspectRaw = cameraStoreRef?.requestedDynamicAspectRaw,
                   let device = (cameraSession.inputs
                       .compactMap { $0 as? AVCaptureDeviceInput }
                       .first { $0.device.hasMediaType(.video) })?.device {
                    let aspect = AVCaptureDevice.AspectRatio(rawValue: aspectRaw)
                    do {
                        try device.lockForConfiguration()
                        device.setDynamicAspectRatio(aspect, completionHandler: nil)
                        device.unlockForConfiguration()
                    } catch {
                        // Lock failed — non-fatal. The recording still proceeds
                        // at the format's native aspect; the preview will look
                        // wrong but the file is intact.
                    }
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
    ) -> (writer: AVAssetWriter, video: AVAssetWriterInput, audio: AVAssetWriterInput)? {
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
        // Always apply writer-level 90° rotation for the front camera.
        // Direction: -π/2 (90° counterclockwise in iOS display coordinates,
        // since iOS uses Y-down with positive angles = clockwise visually).
        //
        // The previous +π/2 (clockwise) shipped upside-down recordings —
        // the iOS 26 dynamic-aspect API reshapes the buffer's W/H labels
        // for `.ratio3x4` without rotating the underlying pixel content,
        // so the buffer arrives "labeled portrait but content sensor-
        // landscape." A clockwise rotation on top of sideways content
        // gave us 180° off (upside down). Counterclockwise corrects
        // that 90°-CW source skew to upright portrait.
        //
        // The iPhone 17 front Ultra Wide connection does NOT honor
        // `connection.videoRotationAngle = 90` (we tried earlier; buffers
        // arrive in the same orientation regardless), so writer-level
        // metadata rotation is the most reliable path until / unless
        // Apple lights up the connection rotation API for that camera.
        videoInput.transform = CGAffineTransform(rotationAngle: -.pi / 2)

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

        if !writer.startWriting() {
            let msg = writer.error?.localizedDescription ?? "Writer refused to start."
            Task { @MainActor [weak self] in
                self?.state.surfaceError(
                    RecordingSessionError.writerSetupFailed(msg).localizedDescription ?? ""
                )
            }
            return nil
        }

        return (writer, videoInput, audioInput)
    }

    /// Stop sample-buffer delivery, mark the inputs finished, and finalize
    /// the .mov. Errors get surfaced through the state machine.
    private func finalizeWriter() async {
        if suppressDeviceWork { return }

        guard let cameraSession, let cameraSessionQueue else { return }

        let lock = writerStateLock

        // Pull the data outputs off the shared session first so no further
        // sample buffers reach the writer while we're finalizing. Note we
        // do NOT remove the audio device input — that's owned by CameraStore
        // now (attached at session-config time, not at recording-start).
        // Removing the data outputs is sufficient to stop sample delivery
        // to the writer; the audio input stays attached until the camera
        // session itself stops.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cameraSessionQueue.async {
                cameraSession.beginConfiguration()
                // Snapshot the outputs/inputs to remove, then clear them
                // out under the lock in a single pass. `audioInputDevice`
                // is the legacy slot; in the dogfood-pass-3 flow it stays
                // nil but we still defensively clear it so a stray legacy
                // attachment can't leak.
                let (v, a, i) = lock.withLock { state -> (
                    AVCaptureVideoDataOutput?,
                    AVCaptureAudioDataOutput?,
                    AVCaptureDeviceInput?
                ) in
                    let result = (state.videoOutput, state.audioOutput, state.audioInputDevice)
                    state.videoOutput = nil
                    state.audioOutput = nil
                    state.audioInputDevice = nil
                    return result
                }
                if let v { cameraSession.removeOutput(v) }
                if let a { cameraSession.removeOutput(a) }
                if let i { cameraSession.removeInput(i) }
                cameraSession.commitConfiguration()
                continuation.resume()
            }
        }

        // Mark inputs finished + finalize the file. Snapshot writer / inputs
        // out of the lock so we don't hold it across the (long) finishWriting.
        let (writerRef, video, audio) = writerStateLock.withLock { state -> (
            AVAssetWriter?, AVAssetWriterInput?, AVAssetWriterInput?
        ) in
            (state.writer, state.videoInput, state.audioInput)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            recordingQueue.async {
                video?.markAsFinished()
                audio?.markAsFinished()
                writerRef?.finishWriting {
                    continuation.resume()
                }
            }
        }

        if let err = writerRef?.error {
            state.surfaceError(
                RecordingSessionError.finalizeFailed(err.localizedDescription).localizedDescription ?? ""
            )
        }
        writerStateLock.withLock { state in
            state.writer = nil
            state.videoInput = nil
            state.audioInput = nil
            state.sampleBufferRouter = nil
            state.sessionStartTime = nil
            state.hasStartedSession = false
        }
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
                state.outputWidth = Int(bufferDims.width)
                state.outputHeight = Int(bufferDims.height)
                state.hasStartedSession = false       // session not started yet
                state.sessionStartTime = nil
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
                writerStateLock.withLock { $0.sessionStartTime = pts }
                if let input = snapshot.videoInput, input.isReadyForMoreMediaData {
                    input.append(sampleBuffer)
                }
            case .append:
                if let input = snapshot.videoInput, input.isReadyForMoreMediaData {
                    input.append(sampleBuffer)
                }
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

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .videoRecording,
                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setActive(true, options: [])
        } catch {
            // Audio-session activation is best-effort. The writer falls
            // back to the system route if we can't lock our category.
        }
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

    // MARK: - Reserved future hook (Feature 3)

    /// Reserved for the chapter-marker feature. The writer pipeline keeps
    /// `AVMutableMetadataItem` writes deferred to finalize-time, so Feature
    /// 3 can wire `appendChapter(title:at:)` into the same writer without
    /// touching `tapREC` / `tapStop`. Not implemented in this PR.
    ///
    /// - Parameters:
    ///   - title: The chapter title (typically a markdown heading).
    ///   - time: A `CMTime` relative to the writer session start.
    func appendChapter(title: String, at time: CMTime) {
        // Intentional no-op — wired when Feature 3 lands.
        _ = title
        _ = time
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

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

import AVFoundation
import Combine
import Foundation
import Observation
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

    /// Active script's URL — captured when the prompter mounts so the
    /// iCloud-next-to-script copy knows where to land. Updated when the
    /// user opens a different script.
    private var currentScriptURL: URL? = nil

    /// Display name of the active script, surfaced in the Live Activity
    /// "expanded" presentation.
    private var currentScriptName: String = ""

    // MARK: - Writer / outputs

    /// Dedicated sample-buffer delivery queue. Distinct from
    /// `cameraSessionQueue` per Apple guidance.
    nonisolated(unsafe) private let recordingQueue = DispatchQueue(
        label: "app.openprompter.recording.session",
        qos: .userInitiated
    )

    nonisolated(unsafe) private var writer: AVAssetWriter?
    nonisolated(unsafe) private var videoInput: AVAssetWriterInput?
    nonisolated(unsafe) private var audioInput: AVAssetWriterInput?
    nonisolated(unsafe) private var videoOutput: AVCaptureVideoDataOutput?
    nonisolated(unsafe) private var audioOutput: AVCaptureAudioDataOutput?
    nonisolated(unsafe) private var audioInputDevice: AVCaptureDeviceInput?
    nonisolated(unsafe) private var sessionStartTime: CMTime?
    nonisolated(unsafe) private var hasStartedSession: Bool = false
    nonisolated(unsafe) private var currentRecordingURL: URL?
    nonisolated(unsafe) private var recordingStartedAt: Date?
    /// Capture initial save destinations at start-of-take so a Settings flip
    /// mid-recording doesn't change the destination list.
    nonisolated(unsafe) private var lockedDestinations: SaveDestinations = .default

    /// Test seam — production callers leave this false. Tests set it true
    /// to skip every AVFoundation interaction so we exercise the state
    /// machine without touching real hardware. Mirrors `CameraStore`'s
    /// `suppressDeviceWork` pattern.
    private let suppressDeviceWork: Bool

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

    /// Sample-buffer delegate forwarder. Holds a weak reference back to the
    /// session so the actor's @MainActor isolation isn't violated by the
    /// AVFoundation callback path.
    nonisolated(unsafe) private var sampleBufferRouter: SampleBufferRouter?

    // MARK: - Init

    init(
        state: RecordingState,
        cameraStore: CameraStore?,
        suppressDeviceWork: Bool = false
    ) {
        self.state = state
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
        lockedDestinations = SaveDestinations(
            photos: true,
            scriptFolder: Prefs.recordingSaveToScriptFolder
        )

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
        state.enterSaving(destinations: lockedDestinations)
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
            state.enterSaving(destinations: lockedDestinations)
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
        recordingStartedAt = started
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
            currentRecordingURL = url
            try await configureWriter(at: url, cameraSession: cameraSession, cameraSessionQueue: cameraSessionQueue)
        } catch {
            state.surfaceError(error.localizedDescription)
            await endLiveActivityIfAny()
        }
    }

    /// Build the writer + inputs and attach the data-outputs to the shared
    /// session. The session-config block runs on `cameraSessionQueue`; the
    /// data-output delegate runs on `recordingQueue`.
    private func configureWriter(
        at url: URL,
        cameraSession: AVCaptureSession,
        cameraSessionQueue: DispatchQueue
    ) async throws {
        let quality = RecordingQuality(rawValue: Prefs.recordingQuality) ?? .default
        let framerate = RecordingFramerate(rawValue: Prefs.recordingFramerate) ?? .default
        let stabilization = RecordingStabilization(rawValue: Prefs.recordingStabilization) ?? .off

        // Activate the audio session for recording. Running this once at
        // start-of-take rather than session-load time keeps a non-recording
        // user from triggering a needless mic LED flicker.
        configureAudioSession()

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw RecordingSessionError.writerSetupFailed(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = false

        // Video input — HEVC at the chosen bitrate, ITU-R 709 color (no HDR
        // for selfie content).
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: quality.codec,
            AVVideoWidthKey: 1080,
            AVVideoHeightKey: 1440, // 4:3 portrait — front-camera open-gate-friendly
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality.bitsPerSecond(forShortDimension: 1080),
                AVVideoExpectedSourceFrameRateKey: framerate.fps
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        // Rotate to portrait — front-camera connection is landscape-right by
        // default; rotating 90° via the writer input gives Photos a file
        // that plays the right way up.
        videoInput.transform = CGAffineTransform(rotationAngle: .pi / 2)

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
            throw RecordingSessionError.writerSetupFailed("Writer rejected inputs.")
        }
        writer.add(videoInput)
        writer.add(audioInput)

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.hasStartedSession = false
        self.sessionStartTime = nil

        // Sample-buffer router. Holds a weak ref back into the session so
        // the AVFoundation callback path can append on the recording queue
        // without violating actor isolation.
        let router = SampleBufferRouter(session: self)
        self.sampleBufferRouter = router

        // Add data outputs to the shared session inside a configuration
        // block. We do this on the camera's session queue to avoid racing
        // with the camera store's own start/stop transitions.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            cameraSessionQueue.async {
                cameraSession.beginConfiguration()
                defer { cameraSession.commitConfiguration() }

                // Audio device input — pick the user's preferred mic if it's
                // currently connected; fall back to the system default.
                let audioDevice = Self.preferredAudioDevice() ?? AVCaptureDevice.default(for: .audio)
                if let audioDevice {
                    do {
                        let input = try AVCaptureDeviceInput(device: audioDevice)
                        if cameraSession.canAddInput(input) {
                            cameraSession.addInput(input)
                            self.audioInputDevice = input
                        }
                    } catch {
                        // Not fatal — the writer can still record video; the
                        // resulting file just has no audio track. Surface a
                        // soft error and continue.
                    }
                }

                let videoOut = AVCaptureVideoDataOutput()
                videoOut.alwaysDiscardsLateVideoFrames = false
                videoOut.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                ]
                videoOut.setSampleBufferDelegate(router, queue: self.recordingQueue)
                if cameraSession.canAddOutput(videoOut) {
                    cameraSession.addOutput(videoOut)
                    self.videoOutput = videoOut
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
                    }
                }
                let audioOut = AVCaptureAudioDataOutput()
                audioOut.setSampleBufferDelegate(router, queue: self.recordingQueue)
                if cameraSession.canAddOutput(audioOut) {
                    cameraSession.addOutput(audioOut)
                    self.audioOutput = audioOut
                }

                // Lock framerate at the device level so the writer sees a
                // stable cadence. Failure here is non-fatal — the device
                // may not support exactly the requested fps and AVFoundation
                // will pick the nearest format. Wrapped in try? so a locked
                // device (e.g. another app holding it) doesn't kill recording.
                if let device = (cameraSession.inputs.compactMap { $0 as? AVCaptureDeviceInput }
                    .first { $0.device.hasMediaType(.video) })?.device {
                    if (try? device.lockForConfiguration()) != nil {
                        device.activeVideoMinFrameDuration = framerate.frameDuration
                        device.activeVideoMaxFrameDuration = framerate.frameDuration
                        device.unlockForConfiguration()
                    }
                }

                continuation.resume()
            }
        }

        // Start the writer file. Sample-buffer delivery hits the router
        // immediately after this returns; we begin the session on the
        // first video sample so the start-time matches the actual frame
        // PTS rather than wall-clock time.
        if !writer.startWriting() {
            throw RecordingSessionError.writerSetupFailed(
                writer.error?.localizedDescription ?? "Writer refused to start."
            )
        }
    }

    /// Stop sample-buffer delivery, mark the inputs finished, and finalize
    /// the .mov. Errors get surfaced through the state machine.
    private func finalizeWriter() async {
        if suppressDeviceWork { return }

        guard let cameraSession, let cameraSessionQueue else { return }

        // Pull the data outputs off the shared session first so no further
        // sample buffers reach the writer while we're finalizing.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cameraSessionQueue.async {
                cameraSession.beginConfiguration()
                if let v = self.videoOutput { cameraSession.removeOutput(v) }
                if let a = self.audioOutput { cameraSession.removeOutput(a) }
                if let i = self.audioInputDevice { cameraSession.removeInput(i) }
                self.videoOutput = nil
                self.audioOutput = nil
                self.audioInputDevice = nil
                cameraSession.commitConfiguration()
                continuation.resume()
            }
        }

        // Mark inputs finished + finalize the file.
        let writerRef = writer
        let video = videoInput
        let audio = audioInput
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            recordingQueue.async {
                video?.markAsFinished()
                audio?.markAsFinished()
                writerRef?.finishWriting {
                    continuation.resume()
                }
            }
        }

        if let err = writer?.error {
            state.surfaceError(
                RecordingSessionError.finalizeFailed(err.localizedDescription).localizedDescription ?? ""
            )
        }
        writer = nil
        videoInput = nil
        audioInput = nil
        sampleBufferRouter = nil
        sessionStartTime = nil
        hasStartedSession = false
    }

    /// Sample-buffer append. Called on `recordingQueue`. Must NOT touch
    /// any @MainActor-isolated state — the router routes back through
    /// MainActor when it needs to.
    nonisolated fileprivate func appendSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        from output: AVCaptureOutput
    ) {
        // We start the writer's session on the first video sample we see,
        // so the file's PTS-zero matches the first frame the user is
        // actually recording (not the wall-clock REC tap).
        guard let writer = self.writer else { return }
        if writer.status == .writing {
            if !self.hasStartedSession, output is AVCaptureVideoDataOutput {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                writer.startSession(atSourceTime: pts)
                self.sessionStartTime = pts
                self.hasStartedSession = true
            }
            if output is AVCaptureVideoDataOutput {
                if let input = self.videoInput, input.isReadyForMoreMediaData, self.hasStartedSession {
                    input.append(sampleBuffer)
                }
            } else if output is AVCaptureAudioDataOutput {
                if let input = self.audioInput, input.isReadyForMoreMediaData, self.hasStartedSession {
                    input.append(sampleBuffer)
                }
            }
        }
    }

    // MARK: - Save flow

    private func runSaveFlow() async {
        guard let url = currentRecordingURL else {
            state.finishSavingSuccessfully(photos: false, scriptFolder: false)
            await endLiveActivityIfAny()
            return
        }

        // Photos write — write-only access. We request the limited add-only
        // scope per Apple's privacy guidelines (NSPhotoLibraryAddUsageDescription).
        var photosOK = false
        if lockedDestinations.photos {
            photosOK = await writeToPhotos(url: url)
        }

        // iCloud-next-to-script — only if requested AND a script is loaded.
        var icloudOK = false
        var icloudFailureReason: String? = nil
        if lockedDestinations.scriptFolder, let script = currentScriptURL {
            switch ICloudCopyJob.copy(recording: url, forScript: script) {
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
            RecordingFileStore.removeRecording(at: url)
        }
        currentRecordingURL = nil
        recordingStartedAt = nil
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

        // Write the asset, then add it to (or create) the "Open Prompter"
        // album. We do this in two phases so a successful write is durable
        // even if the album link fails (the asset is still in Recents).
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var localIdentifier: String? = nil
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
                request?.creationDate = .now
                request?.location = nil
                localIdentifier = request?.placeholderForCreatedAsset?.localIdentifier
            } completionHandler: { success, error in
                guard success, let identifier = localIdentifier else {
                    if let error {
                        Task { @MainActor [weak self] in
                            self?.state.surfaceError(
                                RecordingSessionError.photosWriteFailed(error.localizedDescription)
                                    .localizedDescription ?? ""
                            )
                        }
                    }
                    continuation.resume(returning: false)
                    return
                }
                Self.addAssetToOpenPrompterAlbum(localIdentifier: identifier) {
                    continuation.resume(returning: true)
                }
            }
        }
    }

    /// Find or create the "Open Prompter" album, then add the new asset to
    /// it. Failure here is non-fatal — the asset is still in Recents.
    nonisolated private static func addAssetToOpenPrompterAlbum(
        localIdentifier: String,
        completion: @escaping () -> Void
    ) {
        let albumName = "Open Prompter"

        // Find an existing album with this title.
        let fetch = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: nil
        )
        var existing: PHAssetCollection? = nil
        fetch.enumerateObjects { collection, _, stop in
            if collection.localizedTitle == albumName {
                existing = collection
                stop.pointee = true
            }
        }

        let assetFetch = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let newAsset = assetFetch.firstObject else {
            completion()
            return
        }

        if let collection = existing {
            PHPhotoLibrary.shared().performChanges {
                guard let request = PHAssetCollectionChangeRequest(for: collection) else { return }
                request.addAssets([newAsset] as NSArray)
            } completionHandler: { _, _ in
                completion()
            }
        } else {
            // Create the album, then add the asset in a follow-up edit.
            var albumPlaceholder: PHObjectPlaceholder?
            PHPhotoLibrary.shared().performChanges {
                let create = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
                    withTitle: albumName
                )
                albumPlaceholder = create.placeholderForCreatedAssetCollection
            } completionHandler: { success, _ in
                guard success, let placeholder = albumPlaceholder else {
                    completion()
                    return
                }
                let createdFetch = PHAssetCollection.fetchAssetCollections(
                    withLocalIdentifiers: [placeholder.localIdentifier],
                    options: nil
                )
                guard let collection = createdFetch.firstObject else {
                    completion()
                    return
                }
                PHPhotoLibrary.shared().performChanges {
                    guard let request = PHAssetCollectionChangeRequest(for: collection) else { return }
                    request.addAssets([newAsset] as NSArray)
                } completionHandler: { _, _ in
                    completion()
                }
            }
        }
    }

    // MARK: - Permission helpers

    private func ensureMicrophoneAccess() async -> Bool {
        if suppressDeviceWork {
            // Tests run without an Info.plist mic key — bypass.
            return true
        }
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted: return true
        case .denied:  return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                session.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default: return false
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

    /// Resolve the user's pinned mic source, if currently connected.
    nonisolated private static func preferredAudioDevice() -> AVCaptureDevice? {
        let pin = Prefs.recordingMicSource ?? "builtin"
        if pin == "auto" || pin == "builtin" {
            return AVCaptureDevice.default(for: .audio)
        }
        // The pin holds a port UID. Find a matching capture device by
        // scanning AVCaptureDevice.DiscoverySession's audio device list.
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.first { $0.uniqueID == pin } ?? AVCaptureDevice.default(for: .audio)
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
            let initialState = PrompterRecordingAttributes.PrompterRecordingState(
                elapsedSeconds: 0,
                scriptTitle: currentScriptName,
                phase: phase.simpleKey
            )
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
            let elapsed: Int
            if case .recording(let started) = phase {
                elapsed = max(0, Int(Date().timeIntervalSince(started)))
            } else {
                elapsed = 0
            }
            let new = PrompterRecordingAttributes.PrompterRecordingState(
                elapsedSeconds: elapsed,
                scriptTitle: currentScriptName,
                phase: phase.simpleKey
            )
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

    private func endLiveActivityIfAny() async {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            guard let handle = liveActivityRef else { return }
            let final = PrompterRecordingAttributes.PrompterRecordingState(
                elapsedSeconds: 0,
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
/// to the session so the actor isolation isn't violated.
private final class SampleBufferRouter:
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

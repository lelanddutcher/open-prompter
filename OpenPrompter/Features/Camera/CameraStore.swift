//
//  CameraStore.swift
//  OpenPrompter
//
//  Owner of the AVCaptureSession. Knows the user's chosen `CameraStyle` and
//  the camera permission status. Camera position is hardcoded to `.front` —
//  selfie creators are the dominant audience and the rear-camera affordance
//  was confusing enough that we dropped it. Lifecycle:
//
//  - `style != .off` AND permission granted  → session running
//  - `style == .off` OR permission denied    → session stopped, `style` snaps
//                                              to `.off` and a banner cue
//                                              fires for the UI to surface
//  - app background / scenePhase != .active  → session stopped (privacy LED)
//
//  `AVCaptureSession.startRunning()` blocks; we run it on a dedicated
//  serial queue per Apple guidance and fan @MainActor-published state
//  back to SwiftUI.
//
//  Feature 1 covers the picker, preview, gestures, and tally light. Feature 2
//  will add an `AVAssetWriter`-driven sample-buffer pipeline and the real
//  recording state. This store is intentionally agnostic of recording — it
//  hands the preview layer a reference to the session, no more.
//

import AVFoundation
import Foundation
import Observation
import os

#if canImport(UIKit)
import UIKit
#endif

#if DEBUG
/// `os_log` channel tagged `[Behind-Mode-Debug]`. Tracing the chip-tap →
/// session-flip → preview-mount sequence on real iPhone 17 hardware is the
/// only way to verify the pip → behind path; lab + simulator can't repro
/// because there's no real camera. Filter Console.app on the subsystem to
/// follow a take. Kept behind `#if DEBUG` so production builds don't carry
/// the cost.
fileprivate let behindLog = Logger(
    subsystem: "app.openprompter.camera",
    category: "Behind-Mode-Debug"
)
#endif

@Observable
@MainActor
final class CameraStore {

    // MARK: - Public state

    /// Current composition mode. Setting this triggers the lifecycle
    /// transitions documented above. Persisted to `Prefs.cameraStyle` so
    /// every paired prompter open in the user's session re-loads it.
    private(set) var style: CameraStyle

    /// Last known authorization status. Refreshed on `requestAccessIfNeeded()`
    /// and via the AVFoundation observer on init. SwiftUI reads through this
    /// to decide whether to show the banner or the live preview.
    private(set) var authorization: AVAuthorizationStatus

    /// Set when permission was denied during a user-initiated mode switch,
    /// so the SwiftUI layer can surface the "Camera access is off — open
    /// Settings" banner exactly once per denial. Cleared after the UI
    /// reads it via `consumePermissionDenialBanner()`.
    private(set) var pendingPermissionDeniedBanner: Bool = false

    /// True while the session is running. Useful for tests and for the
    /// preview view to know when to wire its layer up.
    private(set) var isSessionRunning: Bool = false

    /// The shared capture session. Exposed so `CameraPreview` can hand it
    /// to its underlying `AVCaptureVideoPreviewLayer`. Owned strictly by
    /// the store — callers must NOT add inputs/outputs of their own.
    let session: AVCaptureSession = AVCaptureSession()

    // MARK: - Internals

    /// Apple-recommended pattern: a serial queue for session config so the
    /// blocking `startRunning()` / `stopRunning()` calls don't lock up
    /// `MainActor`. All `beginConfiguration` / `commitConfiguration` blocks
    /// happen here.
    nonisolated(unsafe) private let sessionQueue = DispatchQueue(
        label: "app.openprompter.camera.session",
        qos: .userInitiated
    )

    /// Read-only accessor for the session queue. Recording uses this to
    /// add/remove its own inputs/outputs without racing the camera store's
    /// own start/stop transitions. Marked `internal` so RecordingSession
    /// can read it; the queue itself stays unique to the camera store.
    nonisolated var _exposedSessionQueueRef: DispatchQueue { sessionQueue }

    /// Currently-attached camera input. `nil` until `start()` succeeds.
    nonisolated(unsafe) private var currentInput: AVCaptureDeviceInput?

    /// Currently-attached audio input. Nil until `configureInputsLocked()`
    /// runs OR if no audio device is available. Attached at session-config
    /// time (NOT at recording-start time) so the dynamic aspect ratio
    /// reshape and the audio-input addition don't fight over the same
    /// session-config bracket. Adding the audio input mid-recording was
    /// the dogfood-pass-3 cause of the "PiP stretches when REC tap fires"
    /// symptom — the begin/commit configuration block needed to attach
    /// audio re-published the format and the iOS 26 dynamic-aspect reshape
    /// reverted to nominal 4:3 until the next reshape tick. Attaching
    /// audio at session-config time keeps the reshape stable across
    /// recording start. The audio data output (the bit that actually
    /// captures audio samples to the writer) lives in RecordingSession;
    /// the input being attached when recording isn't active is harmless.
    nonisolated(unsafe) private var currentAudioInput: AVCaptureDeviceInput?

    /// Read-only accessor exposed to RecordingSession so it knows whether
    /// to attach an audio input itself (legacy fallback) or rely on the
    /// session-level pre-attached one. Production callers go through
    /// `currentAudioInputDevice` to read the current AVCaptureDeviceInput.
    nonisolated var currentAudioInputDevice: AVCaptureDeviceInput? {
        currentAudioInput
    }

    /// Pre-attached video data output. Lives on the camera session for the
    /// session's full lifetime; sample delivery is gated by toggling
    /// `setSampleBufferDelegate(router, queue:)` between the recording
    /// session's router and `nil`. This is the dogfood-pass-8 fix for the
    /// "PiP squeeze on REC tap" symptom — the previous design added the
    /// data outputs inside a `beginConfiguration / commitConfiguration`
    /// block at REC tap, and that bracket re-evaluated the connection
    /// graph and visibly reverted the iOS 26 dynamic-aspect reshape for
    /// one or two frames before the OS re-applied it. Pre-attaching at
    /// session-config time means REC tap touches no session config, so
    /// the preview can never reshape mid-take.
    ///
    /// Battery cost is negligible: `AVCaptureVideoDataOutput` is a raw
    /// pixel-buffer pump, NOT an encoder. With the delegate set to nil,
    /// AVFoundation discards samples at the framework level — no buffers
    /// reach our recording queue, no work runs. Apple's own AVCam
    /// reference app uses exactly this pattern.
    nonisolated(unsafe) private var _videoDataOutput: AVCaptureVideoDataOutput?
    nonisolated(unsafe) private var _audioDataOutput: AVCaptureAudioDataOutput?

    /// RecordingSession reads these to attach its sample buffer delegate
    /// at REC tap (and clear it at stop). `nil` while the session is in
    /// `.off` mode (data outputs are attached lazily on first non-`.off`
    /// configure, alongside the camera input + dynamic-aspect reshape +
    /// audio input — all in one shared begin/commit bracket).
    nonisolated var preAttachedVideoOutput: AVCaptureVideoDataOutput? {
        _videoDataOutput
    }
    nonisolated var preAttachedAudioOutput: AVCaptureAudioDataOutput? {
        _audioDataOutput
    }

    /// Raw aspect-ratio string we requested via `setDynamicAspectRatio` on
    /// iOS 26+, kept so RecordingSession can compute the post-reshape buffer
    /// dimensions even when `device.dynamicDimensions` reads {0,0} (the API
    /// is async; reads can race the actual reshape on first session start).
    /// Nil on older OS / older hardware where dynamic aspect isn't in play.
    /// Read-only via `requestedDynamicAspectRaw`.
    nonisolated(unsafe) private var _requestedDynamicAspectRaw: String?

    /// Read-only mirror of the last requested dynamic aspect ratio (raw
    /// string). RecordingSession reads this to compute post-reshape dims.
    nonisolated var requestedDynamicAspectRaw: String? {
        // Loaded from a single property write inside `configureInputsLocked`;
        // a torn read isn't possible because `String?` writes are atomic at
        // pointer width. Direct read is fine.
        _requestedDynamicAspectRaw
    }

    /// Set by tests to skip the actual AVCaptureSession plumbing. Production
    /// callers leave it false. Tests that exercise state-machine transitions
    /// flip this on so we don't try to acquire a real camera in a unit test
    /// process.
    private let suppressDeviceWork: Bool

    // MARK: - Init

    init(suppressDeviceWork: Bool = false) {
        self.suppressDeviceWork = suppressDeviceWork
        // Read persisted style; if a user wrote a value we no longer recognize
        // (downgrade scenario), fall back to `.off` rather than crashing.
        let raw = Prefs.cameraStyle
        self.style = CameraStyle(rawValue: raw) ?? .off
        self.authorization = AVCaptureDevice.authorizationStatus(for: .video)
    }

    // MARK: - Mode transitions (the core state machine)

    /// User-initiated mode change from the chip or Settings. Triggers the
    /// permission prompt the first time we move to a non-`.off` mode. On
    /// denial, snaps back to `.off` and sets `pendingPermissionDeniedBanner`.
    ///
    /// We update `style` _optimistically_ — the moment we know we'll keep
    /// the new mode (permission was already granted, or we're heading to
    /// `.off`), so SwiftUI can re-render the chip/tile immediately. The
    /// blocking AVFoundation start happens on `sessionQueue` after the
    /// state flip, so the preview catches up while the chip already looks
    /// correct. Without this, the chip froze for 2-3s whenever the user
    /// re-enabled the camera (the dogfood report that triggered the fix).
    ///
    /// Post-dogfood-pass-2: revert-on-failure now ONLY fires when we're
    /// transitioning from `.off` (i.e. starting the session for real). On a
    /// non-off → non-off transition (pip → behind, behind → pip) the session
    /// is already running and we don't need to verify it again. The
    /// over-aggressive revert from the previous fixup pass was the actual
    /// pip → behind bug — it tripped on a stale `isSessionRunning` read
    /// during the brief begin/commit window AVFoundation opens whenever a
    /// SwiftUI view-tree change re-mounts the preview layer.
    func setStyle(_ new: CameraStyle) async {
        guard new != style else { return }
        let previous = style

        if new == .off {
            // Flip the UI state first — there's no permission gate to wait
            // on, and the user wants the chip to show "off" instantly.
            #if DEBUG
            behindLog.info("setStyle entry old=\(previous.rawValue, privacy: .public) new=off")
            #endif
            style = .off
            persistStyle()
            await stop()
            return
        }

        // We're moving to .pip or .behind — make sure we have permission.
        let granted = await requestAccessIfNeeded()
        guard granted else {
            // Snap back to off; surface a one-shot banner for the UI to read.
            if style != .off { style = .off }
            persistStyle()
            pendingPermissionDeniedBanner = true
            await stop()
            return
        }

        // Optimistic update: flip `style` before awaiting the session start.
        // The PiP tile renders the moment SwiftUI reads `style == .pip`,
        // even if the first preview frame hasn't arrived. The user sees the
        // tile instantly with a black preview that fills in shortly after.
        style = new
        persistStyle()
        #if DEBUG
        behindLog.info(
            "setStyle entry old=\(previous.rawValue, privacy: .public) new=\(new.rawValue, privacy: .public) (calling start)"
        )
        #endif
        await start()
        #if DEBUG
        behindLog.info(
            "setStyle post-start running=\(self.isSessionRunning, privacy: .public) style=\(self.style.rawValue, privacy: .public)"
        )
        #endif

        // Revert is ONLY relevant when we just kicked the session up from
        // an off state. Non-off → non-off transitions (pip → behind, etc.)
        // are config-only — the session is still running, so don't second-
        // guess it. The previous pass's blanket revert was the actual
        // pip → behind bug.
        if previous == .off, !isSessionRunning, !suppressDeviceWork {
            #if DEBUG
            behindLog.error(
                "start() did not produce a running session — reverting to off"
            )
            #endif
            style = .off
            persistStyle()
            await stop()
        }
    }

    /// Resume session if we should be running (mode != off, permission granted).
    /// Called on `scenePhase == .active`, view appearance, etc. Idempotent.
    func resume() async {
        guard style != .off else { return }
        guard authorization == .authorized else { return }
        await start()
    }

    /// Stop the session unconditionally — used on view disappear, app
    /// background, and inside `setStyle(.off)`. Blocks until the session
    /// queue acks the stop so the privacy LED extinguishes promptly.
    func suspend() async {
        await stop()
    }

    /// SwiftUI banner consumer. Returns true exactly once per denial event,
    /// so the prompter can show the "open Settings to enable" banner without
    /// re-firing on every layout pass.
    func consumePermissionDenialBanner() -> Bool {
        defer { pendingPermissionDeniedBanner = false }
        return pendingPermissionDeniedBanner
    }

    // MARK: - Permission

    /// Request camera authorization if the user hasn't decided yet. Returns
    /// `true` if we're authorized (or were already), `false` if denied or
    /// restricted. iOS shows its system prompt for `.notDetermined`.
    private func requestAccessIfNeeded() async -> Bool {
        // Test seam: when device work is suppressed AND a test pre-seeded
        // an authorized status via `prepareTestAuthorization(_:)`, honor
        // it directly. Lets unit tests exercise the .pip → .behind happy
        // path without requiring an Info.plist NSCameraUsageDescription
        // in the test bundle.
        if suppressDeviceWork && authorization == .authorized {
            return true
        }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            authorization = .authorized
            return true
        case .denied, .restricted:
            authorization = status
            return false
        case .notDetermined:
            // System prompt. Suspend on the test path so we never trigger a
            // hidden Info.plist requirement during unit tests.
            if suppressDeviceWork {
                authorization = .denied
                return false
            }
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            authorization = granted ? .authorized : .denied
            return granted
        @unknown default:
            authorization = .denied
            return false
        }
    }

    /// Test seam — pre-seed the authorization status. Only honored when
    /// `suppressDeviceWork: true`. Production callers should never use
    /// this; the real authorization status comes from AVFoundation.
    func prepareTestAuthorization(_ status: AVAuthorizationStatus) {
        guard suppressDeviceWork else { return }
        self.authorization = status
    }

    // MARK: - AVCaptureSession plumbing

    /// Configure inputs (front camera) and start the session. The blocking
    /// `startRunning()` runs on `sessionQueue`; we await its completion so
    /// the @MainActor caller can flip UI state once the session is live.
    /// `start()` is idempotent — re-entry while the session is already
    /// running is a no-op (`if !session.isRunning`).
    ///
    /// Dogfood-pass-2: the previous pass wrapped a begin/commit configuration
    /// block around every `start()` call, even when the input was already
    /// attached. That empty bracket on iOS 26 caused a brief frame-delivery
    /// window where the preview layer drew its background color — the actual
    /// "PiP goes black" symptom on .pip → .behind. We now only enter a config
    /// bracket if we ACTUALLY need to add the input. On a non-off → non-off
    /// transition this short-circuits to a no-op `if !session.isRunning`
    /// check (which also returns false → skip `startRunning`), and the
    /// running session keeps delivering frames uninterrupted.
    private func start() async {
        if suppressDeviceWork {
            isSessionRunning = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                // Only wrap a begin/commit when we actually need to attach
                // an input. Empty brackets on a running session interrupt
                // frame delivery on iOS 26 — the dogfood symptom.
                if self.currentInput == nil {
                    self.session.beginConfiguration()
                    self.configureInputsLocked()
                    self.session.commitConfiguration()
                }
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                let running = self.session.isRunning
                #if DEBUG
                behindLog.info(
                    "start() complete running=\(running, privacy: .public) hasInput=\(self.currentInput != nil, privacy: .public)"
                )
                #endif
                Task { @MainActor in
                    self.isSessionRunning = running
                    continuation.resume()
                }
            }
        }
    }

    /// Stop the running session. Cleared `currentInput` so the next start
    /// rebuilds from scratch — it's cheap and avoids stale-device bugs after
    /// a backgrounding cycle.
    private func stop() async {
        if suppressDeviceWork {
            isSessionRunning = false
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                self.session.beginConfiguration()
                if let input = self.currentInput {
                    self.session.removeInput(input)
                }
                self.currentInput = nil
                if let audio = self.currentAudioInput {
                    self.session.removeInput(audio)
                }
                self.currentAudioInput = nil
                self.session.commitConfiguration()
                Task { @MainActor in
                    self.isSessionRunning = false
                    continuation.resume()
                }
            }
        }
    }

    /// Build and attach the front-camera input. Must be called inside a
    /// `beginConfiguration` block (or equivalent — `start()` and the
    /// reconfigure path both set up configuration brackets around the call).
    /// Position is hardcoded `.front` — the rear camera affordance was
    /// dropped in the post-merge dogfooding pass.
    ///
    /// Open-gate selection is tiered (see `selectOpenGateFormat`):
    ///   1. iOS 26 + iPhone 17 family → pick a format that exposes
    ///      `supportedDynamicAspectRatios` and switch the buffer to 1×1
    ///      (full square sensor readout, ~3024×3024).
    ///   2. Older iOS / older hardware → pick the largest pixel-area format
    ///      whose framerate range covers the user's fps target. The native
    ///      4:3 sensor IS the open gate on those devices.
    ///
    /// We probe BOTH `.builtInWideAngleCamera` and `.builtInUltraWideCamera`
    /// for the front position — Apple ships the iPhone 17 square sensor
    /// under `.builtInUltraWideCamera`. We pick whichever device exposes
    /// formats with `supportedDynamicAspectRatios` populated; otherwise we
    /// fall back to whichever device exists (preferring wide-angle).
    ///
    /// Critical: `session.sessionPreset = .inputPriority` MUST be set
    /// before we assign `device.activeFormat` — otherwise the next
    /// `commitConfiguration` silently overrides our format choice with the
    /// preset's default. The caller already holds open `beginConfiguration`,
    /// so we set the preset here while we're inside the bracket.
    nonisolated private func configureInputsLocked() {
        guard let device = Self.selectFrontCameraDevice() else {
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                currentInput = input
            }
        } catch {
            // No usable input — leave currentInput nil. The preview layer
            // will draw black and the UI will still function (e.g. the user
            // can switch back to .off without crashing).
            return
        }

        // Set sessionPreset = .inputPriority BEFORE writing activeFormat.
        // Named presets (.high, .hd1920x1080, etc.) silently win over
        // explicit format assignments at commitConfiguration time.
        session.sessionPreset = .inputPriority

        // Resolve the user's fps target and aspect-ratio choice, then run
        // the tiered selection. Aspect defaults to `.ratio9x16` for fresh
        // installs and `.openGate` for migrated users — the format selector
        // honors the choice when iOS 26 + the format support it, and falls
        // back to the historical largest-area `.openGate` behaviour
        // otherwise.
        let framerate = RecordingFramerate(rawValue: Prefs.recordingFramerate) ?? .default
        let fps = Double(framerate.fps)
        let userAspect = RecordingAspect(rawValue: Prefs.recordingAspect) ?? .default
        guard let choice = Self.selectOpenGateFormat(
            from: device.formats,
            preferredFPS: fps,
            userAspect: userAspect
        ) else {
            // No format covers the requested framerate. Leave the device
            // default in place rather than misconfiguring it.
            #if DEBUG
            print("[CameraStore] No format supports \(framerate.fps) fps; using device default.")
            #endif
            return
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = choice.format

            // iOS 26+ dynamic aspect — reshape the buffer to 1×1 (or first
            // declared aspect) when the format supports it. On iPhone 17
            // family front camera this is what gives us the full square
            // sensor readout (true open gate).
            if #available(iOS 26.0, *), let aspect = choice.dynamicAspect {
                device.setDynamicAspectRatio(aspect, completionHandler: nil)
                _requestedDynamicAspectRaw = aspect.rawValue
            } else {
                _requestedDynamicAspectRaw = nil
            }

            // Pin the framerate while we're inside lockForConfiguration —
            // we already verified the chosen format supports `fps` in
            // selectOpenGateFormat, so it's safe to lock both bounds.
            device.activeVideoMinFrameDuration = framerate.frameDuration
            device.activeVideoMaxFrameDuration = framerate.frameDuration

            device.unlockForConfiguration()
        } catch {
            // Lock failed (another app holds the device, etc.). The session
            // still runs at the device default — non-fatal.
        }

        // Attach the audio input AT SESSION-CONFIG TIME (not at REC-tap
        // time). Doing this here means the dynamic-aspect reshape and the
        // audio-input attachment share the same begin/commit bracket — so
        // when the user later taps REC, the only thing happening is the
        // data-output addition (which doesn't re-publish the format).
        // Before this fix, recording-start added the audio input inside its
        // own configuration bracket, which on iPhone 17 + iOS 26 caused the
        // 1×1 reshape to revert to nominal 4:3 for one frame — the user's
        // "PiP stretches when REC starts" report. The audio device is
        // harmless when recording isn't active: only the audio data output
        // (pre-attached just below) gates whether samples reach the writer.
        attachAudioInputLocked()

        // Pre-attach the video + audio data outputs. These also live in
        // the same begin/commit bracket as the camera input, audio input,
        // and dynamic-aspect reshape. Sample delivery to the writer is
        // gated entirely by toggling `setSampleBufferDelegate(_, queue:)`
        // between the recording session's router and nil; with the
        // delegate nil, AVFoundation discards samples at the framework
        // level so there's no encoder cost / no battery drain.
        //
        // This is the dogfood-pass-8 fix for "PiP squeezes when REC is
        // tapped." The old design did `cameraSession.addOutput(...)`
        // inside `RecordingSession.configureWriter`, which forced its
        // own `beginConfiguration / commitConfiguration` cycle that
        // re-evaluated the connection graph and on iPhone 17 + iOS 26
        // visibly reverted the 1×1 reshape for one or two frames before
        // the OS re-applied. Pre-attaching means REC tap never opens a
        // session-config bracket — the preview can't reshape mid-take.
        attachDataOutputsLocked()
    }

    /// Pre-attach the video + audio data outputs that the recording
    /// pipeline writes through. Must be called inside the existing
    /// `beginConfiguration` bracket opened by `start()`. Idempotent:
    /// re-runs (e.g. after a stop / restart cycle) skip outputs that
    /// are already attached so we don't accumulate duplicate connections.
    nonisolated private func attachDataOutputsLocked() {
        if _videoDataOutput == nil {
            let videoOut = AVCaptureVideoDataOutput()
            videoOut.alwaysDiscardsLateVideoFrames = false
            videoOut.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            ]
            if session.canAddOutput(videoOut) {
                session.addOutput(videoOut)
                _videoDataOutput = videoOut

                if let connection = videoOut.connection(with: .video) {
                    // Front camera mirroring rules: write the recording
                    // file as the camera saw it (NOT mirrored), preview
                    // is mirrored elsewhere via the SwiftUI scale modifier.
                    if connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = false
                    }
                    // NOTE: we deliberately do NOT call
                    // `connection.videoRotationAngle = 90` here. The
                    // dogfood-pass-8 attempt at capture-time rotation
                    // worked on iPhone 17 + iOS 26.x but stacked with
                    // the writer's `-π/2` transform → 180° net rotation
                    // → recordings shipped upside down. Rotation lives
                    // exclusively at the writer level
                    // (`videoInput.transform = -π/2` in
                    // `lazilyStartWriterOnFirstSample`) so the source
                    // of truth for buffer orientation is one place.
                }
            }
        }
        if _audioDataOutput == nil {
            let audioOut = AVCaptureAudioDataOutput()
            if session.canAddOutput(audioOut) {
                session.addOutput(audioOut)
                _audioDataOutput = audioOut
            }
        }
    }

    /// Attach the user's preferred mic (or system default) to the session.
    /// Must be called inside a `beginConfiguration` bracket. Failure is
    /// non-fatal — the writer can still record video; the file just has no
    /// audio track and the chip surfaces a strikethrough-mic glyph during
    /// the take.
    nonisolated private func attachAudioInputLocked() {
        guard let audioDevice = Self.preferredAudioDevice() ?? AVCaptureDevice.default(for: .audio) else {
            return
        }
        do {
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            if session.canAddInput(audioInput) {
                session.addInput(audioInput)
                currentAudioInput = audioInput
            }
        } catch {
            // Audio device input failed — non-fatal. RecordingSession's
            // mic-unavailable signal flips when the writer setup later
            // detects no input is attached.
        }
    }

    /// Resolve the user's pinned mic source, if currently connected.
    /// Mirrors the helper RecordingSession used to own; we hoist it here
    /// because audio attachment now lives at session-config time.
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

    /// Probe both `.builtInWideAngleCamera` and `.builtInUltraWideCamera`
    /// for the front position. On iPhone 17 family the square sensor is
    /// exposed as `.builtInUltraWideCamera`; on older phones only
    /// `.builtInWideAngleCamera` exists. We prefer whichever device has any
    /// format with `supportedDynamicAspectRatios` populated (iOS 26+) — that's
    /// the indicator that this hardware can do dynamic 1×1. Otherwise we
    /// prefer wide-angle (the historic default), then ultra-wide.
    nonisolated static func selectFrontCameraDevice() -> AVCaptureDevice? {
        // Build a discovery session probing both device types so iPhone 17's
        // ultra-wide square sensor is visible alongside the legacy wide-angle.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera],
            mediaType: .video,
            position: .front
        )
        let candidates = discovery.devices
        guard !candidates.isEmpty else { return nil }

        // iOS 26+: prefer the device that exposes dynamic-aspect formats —
        // that's the iPhone 17 square sensor pathway.
        if #available(iOS 26.0, *) {
            let dynamicRich = candidates
                .map { device -> (device: AVCaptureDevice, count: Int) in
                    let count = device.formats.reduce(0) { acc, f in
                        acc + (f.supportedDynamicAspectRatios.isEmpty ? 0 : 1)
                    }
                    return (device, count)
                }
                .filter { $0.count > 0 }
                .max(by: { $0.count < $1.count })
            if let pick = dynamicRich {
                return pick.device
            }
        }

        // Fallback ordering: wide-angle first (historic default), then
        // ultra-wide. On iPhone 17 with iOS < 26 this lands on wide-angle
        // (which still has a sensible 4:3 readout); on older devices it
        // matches what we shipped before.
        if let wide = candidates.first(where: { $0.deviceType == .builtInWideAngleCamera }) {
            return wide
        }
        return candidates.first
    }

    /// Tiered open-gate format selection.
    ///
    /// - Step 1: filter `formats` to those whose `videoSupportedFrameRateRanges`
    ///   cover `preferredFPS`.
    /// - Step 2 (iOS 26+):
    ///     - When `userAspect == .openGate`, pick the largest dynamic-aspect
    ///       capable format and return it with the historical aspect-pref
    ///       order (4×3 → 1×1 → 3×4 → first declared) — sensor-natural
    ///       full-readout behaviour, unchanged.
    ///     - For a specific `userAspect`, prefer formats that declare the
    ///       requested aspect in `supportedDynamicAspectRatios`. If none
    ///       declare it, fall back to the `.openGate` largest-area path
    ///       (don't try to call `setDynamicAspectRatio` with an unsupported
    ///       value).
    /// - Step 3 (fallback): pick the largest pixel-area candidate regardless
    ///   of aspect; return with `dynamicAspect = nil` so the caller skips
    ///   the iOS 26 reshape call. The user's reframing happens in post.
    /// Returns nil if no format covers `preferredFPS`.
    ///
    /// QA REVIEWER FOCUS: when `userAspect.requiresIOS26` is true on a
    /// pre-iOS-26 OS, the selector skips the dynamic-aspect path entirely
    /// and lands in Step 3. The user's chosen 9:16 / 1:1 will then be
    /// honored on the next iOS upgrade rather than producing a misshapen
    /// recording today.
    nonisolated static func selectOpenGateFormat(
        from formats: [AVCaptureDevice.Format],
        preferredFPS: Double,
        userAspect: RecordingAspect = .openGate
    ) -> OpenGateChoice? {
        let summaries: [(format: AVCaptureDevice.Format, descriptor: FormatDescriptor)] = formats.map { format in
            Self.summarize(format)
        }
        guard let pick = pickOpenGateFormat(
            descriptors: summaries.map { $0.descriptor },
            preferredFPS: preferredFPS,
            userAspect: userAspect
        ) else {
            return nil
        }
        let format = summaries[pick.index].format

        // The raw aspect string is stored verbatim; the typed accessor
        // (`OpenGateChoice.dynamicAspect`) gates on iOS 26 at read time.
        return OpenGateChoice(format: format, dynamicAspectRaw: pick.dynamicAspectRaw)
    }

    /// Summarize an AVCaptureDevice.Format into the pure FormatDescriptor.
    /// Pulls dynamic-aspect support from the iOS 26 API when available.
    nonisolated private static func summarize(
        _ format: AVCaptureDevice.Format
    ) -> (format: AVCaptureDevice.Format, descriptor: FormatDescriptor) {
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let ranges = format.videoSupportedFrameRateRanges.map { range in
            (min: range.minFrameRate, max: range.maxFrameRate)
        }
        var dynamicRatios: [String] = []
        if #available(iOS 26.0, *) {
            dynamicRatios = format.supportedDynamicAspectRatios.map { $0.rawValue }
        }
        return (
            format,
            FormatDescriptor(
                width: Int(dims.width),
                height: Int(dims.height),
                frameRateRanges: ranges,
                supportsDynamicAspectRatios: !dynamicRatios.isEmpty,
                dynamicAspectRatios: dynamicRatios
            )
        )
    }

    /// Pure-value choice surfaced from the open-gate algorithm. The format
    /// reference is the AVFoundation object the caller assigns to
    /// `device.activeFormat`; the optional `dynamicAspect` is the iOS 26+
    /// aspect to apply via `setDynamicAspectRatio`. Nil means "leave the
    /// format's native aspect alone" (older OS, or a format that doesn't
    /// declare dynamic-aspect support).
    struct OpenGateChoice {
        let format: AVCaptureDevice.Format
        @available(iOS 26.0, *)
        var dynamicAspect: AVCaptureDevice.AspectRatio? {
            get {
                guard let raw = _dynamicAspectRaw else { return nil }
                return AVCaptureDevice.AspectRatio(rawValue: raw)
            }
        }
        fileprivate let _dynamicAspectRaw: String?

        @available(iOS 26.0, *)
        init(format: AVCaptureDevice.Format, dynamicAspect: AVCaptureDevice.AspectRatio?) {
            self.format = format
            self._dynamicAspectRaw = dynamicAspect?.rawValue
        }

        init(format: AVCaptureDevice.Format, dynamicAspectRaw: String?) {
            self.format = format
            self._dynamicAspectRaw = dynamicAspectRaw
        }
    }

    /// Lightweight value-type description of an AVCaptureDevice.Format —
    /// only the fields that drive the open-gate decision. Pure value type
    /// so tests can construct fake formats without AVFoundation.
    ///
    /// `supportsDynamicAspectRatios` mirrors whether
    /// `format.supportedDynamicAspectRatios` is non-empty (iOS 26+); the
    /// `dynamicAspectRatios` array carries the raw values
    /// (e.g. "AVCaptureAspectRatio1x1") so the pure helper can pick 1×1
    /// without referencing AVFoundation.
    struct FormatDescriptor: Equatable, Sendable {
        let width: Int
        let height: Int
        let frameRateRanges: [(min: Double, max: Double)]
        let supportsDynamicAspectRatios: Bool
        let dynamicAspectRatios: [String]

        init(
            width: Int,
            height: Int,
            frameRateRanges: [(min: Double, max: Double)],
            supportsDynamicAspectRatios: Bool = false,
            dynamicAspectRatios: [String] = []
        ) {
            self.width = width
            self.height = height
            self.frameRateRanges = frameRateRanges
            self.supportsDynamicAspectRatios = supportsDynamicAspectRatios
            self.dynamicAspectRatios = dynamicAspectRatios
        }

        static func == (lhs: FormatDescriptor, rhs: FormatDescriptor) -> Bool {
            guard lhs.width == rhs.width, lhs.height == rhs.height else { return false }
            guard lhs.frameRateRanges.count == rhs.frameRateRanges.count else { return false }
            for (l, r) in zip(lhs.frameRateRanges, rhs.frameRateRanges) {
                if l.min != r.min || l.max != r.max { return false }
            }
            guard lhs.supportsDynamicAspectRatios == rhs.supportsDynamicAspectRatios else { return false }
            return lhs.dynamicAspectRatios == rhs.dynamicAspectRatios
        }
    }

    /// Pure decision helper. Returns the index of the chosen format and the
    /// raw aspect-ratio string to apply via `setDynamicAspectRatio` (or nil
    /// to leave the format's native aspect alone). Tests target this directly.
    ///
    /// The algorithm:
    ///   1. Filter to formats whose framerate range covers `preferredFPS`.
    ///   2a. When `userAspect == .openGate`: if any candidate has
    ///       `supportsDynamicAspectRatios == true`, pick the largest such
    ///       format with the historical 4×3 → 1×1 → 3×4 → first-declared
    ///       aspect-preference order (sensor-natural full readout).
    ///   2b. When `userAspect` is a specific aspect (9:16, 1:1, 4:3, 16:9):
    ///       prefer the largest dynamic-aspect-capable format that DECLARES
    ///       that aspect. If none declares it, fall through to step 3
    ///       (don't try to apply an unsupported aspect via
    ///       `setDynamicAspectRatio` — that throws).
    ///   3. Else pick the largest pixel-area candidate, `dynamicAspectRaw = nil`.
    ///
    /// QA REVIEWER FOCUS: the `requestedRaw` lookup in Step 2b uses raw
    /// strings (e.g. `"AVCaptureAspectRatio9x16"`) to stay decoupled from
    /// the iOS 26 enum's availability. If you ever add a new aspect, ensure
    /// the raw string you use here matches the `AVCaptureDevice.AspectRatio`
    /// rawValue exactly — a typo silently demotes the user to Step 3.
    nonisolated static func pickOpenGateFormat(
        descriptors: [FormatDescriptor],
        preferredFPS: Double,
        userAspect: RecordingAspect = .openGate
    ) -> (index: Int, dynamicAspectRaw: String?)? {
        // Step 1: filter by framerate support.
        let candidates: [(index: Int, descriptor: FormatDescriptor)] = descriptors
            .enumerated()
            .compactMap { (index, d) in
                guard d.height > 0 else { return nil }
                let coversFPS = d.frameRateRanges.contains { range in
                    preferredFPS >= range.min - 0.01 && preferredFPS <= range.max + 0.01
                }
                return coversFPS ? (index, d) : nil
            }
        guard !candidates.isEmpty else { return nil }

        // Step 2: dynamic-aspect-capable candidates win when present AND
        // either we want open-gate (any aspect declared) or the requested
        // user-aspect is in the candidate's declared list.
        let dynamic = candidates.filter { $0.descriptor.supportsDynamicAspectRatios }

        if userAspect == .openGate {
            // 2a — open-gate: largest dynamic-aspect format with the
            // historical 4×3-first preference (sensor-natural orientation).
            if let best = dynamic.max(by: byPixelArea) {
                // Aspect preference — pinned to .ratio4x3 (landscape 4032×3024)
                // because iOS 26.0 on iPhone 17 reshapes the buffer's reported
                // W/H labels but does NOT rotate the underlying pixel content
                // when a portrait aspect like .ratio3x4 is selected. That means
                // .ratio3x4 produces a portrait-shaped container holding
                // sensor-landscape data: the file's dimensions claim 3024×4032
                // but the actual image inside is sideways. Photos plays it
                // rotated; the PiP tile letterboxes a wide-content frame inside
                // a 3:4 portrait container, both of which the user surfaced in
                // dogfood pass 6.
                //
                // Keeping the buffer at 4:3 landscape — sensor's natural
                // orientation — means the content arrives correctly oriented.
                // We then attach a 90° rotation transform at the writer level
                // (always, for the front camera) so playback shows portrait
                // 3024×4032 with the right-way-up image. The PiP preview
                // letterboxes the 4:3 landscape buffer inside the 3:4 portrait
                // tile (thin black bars top/bottom), matching how iOS Camera
                // shows its small picture-in-picture previews.
                //
                // Order:
                //   1. .ratio4x3 — preferred, sensor-natural orientation.
                //   2. .ratio1x1 — full square sensor readout. iOS 26.0 doesn't
                //      currently expose this in the front camera's supported
                //      aspect set (Apple's stock Camera center-crops 1:1) but
                //      a future iOS may; keeping this as a fallback so the
                //      code path lights up automatically when it does.
                //   3. .ratio3x4 — last resort, only if neither 4:3 nor 1:1 is
                //      declared. Will look rotated until iOS reshapes content.
                //   4. First declared — total fallback.
                let supported = best.descriptor.dynamicAspectRatios
                let fourByThree = "AVCaptureAspectRatio4x3"
                let oneByOne = "AVCaptureAspectRatio1x1"
                let threeByFour = "AVCaptureAspectRatio3x4"
                let aspect: String?
                if supported.contains(fourByThree) {
                    aspect = fourByThree
                } else if supported.contains(oneByOne) {
                    aspect = oneByOne
                } else if supported.contains(threeByFour) {
                    aspect = threeByFour
                } else {
                    aspect = supported.first
                }
                return (best.index, aspect)
            }
        } else {
            // 2b — specific user-aspect. Look for a format that declares it
            // and pick the largest. Raw string mapping matches Apple's
            // `AVCaptureDevice.AspectRatio` rawValue strings.
            let requestedRaw: String
            switch userAspect {
            case .ratio9x16: requestedRaw = "AVCaptureAspectRatio9x16"
            case .ratio1x1:  requestedRaw = "AVCaptureAspectRatio1x1"
            case .ratio4x3:  requestedRaw = "AVCaptureAspectRatio4x3"
            case .ratio16x9: requestedRaw = "AVCaptureAspectRatio16x9"
            case .openGate:  requestedRaw = "" // unreachable
            }
            let matching = dynamic.filter { $0.descriptor.dynamicAspectRatios.contains(requestedRaw) }
            if let best = matching.max(by: byPixelArea) {
                return (best.index, requestedRaw)
            }
            // No format declares the requested aspect. Fall through to
            // Step 3 — pre-iOS-26 OSes land here too because no descriptor
            // has `supportsDynamicAspectRatios == true`. The user gets the
            // largest native-aspect format and reframes in post.
        }

        // Step 3: fallback — largest pixel-area candidate, native aspect.
        if let best = candidates.max(by: byPixelArea) {
            return (best.index, nil)
        }
        return nil
    }

    /// Sort comparator — a < b when a's pixel area is smaller. Used with
    /// `Sequence.max(by:)` to find the largest.
    nonisolated private static func byPixelArea(
        _ lhs: (index: Int, descriptor: FormatDescriptor),
        _ rhs: (index: Int, descriptor: FormatDescriptor)
    ) -> Bool {
        (lhs.descriptor.width * lhs.descriptor.height) <
            (rhs.descriptor.width * rhs.descriptor.height)
    }

    // MARK: - Persistence

    private func persistStyle() {
        Prefs.cameraStyle = style.rawValue
    }
}

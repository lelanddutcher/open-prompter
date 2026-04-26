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

#if canImport(UIKit)
import UIKit
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
    /// Post-dogfood guard: after awaiting `start()`, we verify
    /// `isSessionRunning` is true. Behind-mode was unreliable (2-3 taps to
    /// register) because the optimistic flip left `style = .behind` even
    /// when the session quietly failed to start. Now we revert and surface
    /// a banner so the user isn't staring at a black screen.
    func setStyle(_ new: CameraStyle) async {
        guard new != style else { return }
        let previous = style

        if new == .off {
            // Flip the UI state first — there's no permission gate to wait
            // on, and the user wants the chip to show "off" instantly.
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
        print("[CameraStore] setStyle \(previous.rawValue) -> \(new.rawValue), starting session")
        #endif
        await start()

        // Verify the session is actually running. If it isn't, we'd be
        // leaving the user with a black `.behind` background or a frozen
        // PiP tile. Revert to the previous style so the UI matches reality.
        if !isSessionRunning && !suppressDeviceWork {
            #if DEBUG
            print("[CameraStore] start() failed — reverting style to \(previous.rawValue)")
            #endif
            style = previous
            persistStyle()
            // If the previous style was non-off, leave the (still-stopped)
            // session alone; if it was .off, make sure we're truly stopped.
            if previous == .off {
                await stop()
            }
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
    /// We also enforce the configuration brackets on the start path: even
    /// when the session is already running, we re-check that an input is
    /// attached. The behind-mode dogfood report traced back to a path
    /// where the session had been started, then a config block tore down
    /// inputs without restoring them. Re-running `configureInputsLocked`
    /// inside a configuration block is cheap when the input is already
    /// there (the `canAddInput` guard short-circuits) and fixes the
    /// "session running but no input" stuck state.
    private func start() async {
        if suppressDeviceWork {
            isSessionRunning = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                // Wrap the input attach in begin/commit so concurrent
                // session-config from RecordingSession can't race us.
                self.session.beginConfiguration()
                if self.currentInput == nil {
                    self.configureInputsLocked()
                }
                self.session.commitConfiguration()
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                let running = self.session.isRunning
                #if DEBUG
                if !running {
                    print("[CameraStore] startRunning() did not produce a running session")
                }
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
    /// We also pick a true 4:3 `activeFormat` here. Without this, the device
    /// defaults to a 16:9 HD format and our 1440×1080 writer ends up with
    /// the source letterboxed inside (black bars left/right of the PiP
    /// preview confirmed it). Selecting a 4:3 format gives the front camera
    /// its full sensor readout — true open-gate framing — and the PiP tile
    /// no longer shows side bars because the buffer matches the 3:4 portrait
    /// aspect.
    nonisolated private func configureInputsLocked() {
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .front
        ) else {
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

        // Pick a 4:3 format that supports the user's framerate target.
        // Selection logic lives in `selectFourThreeFormat(...)` (pure,
        // unit-testable) — this function just resolves the framerate from
        // prefs and applies the chosen format under `lockForConfiguration`.
        let framerate = RecordingFramerate(rawValue: Prefs.recordingFramerate) ?? .default
        if let chosen = Self.selectFourThreeFormat(
            from: device.formats,
            preferredFPS: Double(framerate.fps)
        ) {
            do {
                try device.lockForConfiguration()
                device.activeFormat = chosen
                device.unlockForConfiguration()
            } catch {
                // Lock failed (another app holds the device, etc.). The
                // session still runs at the device default — non-fatal.
            }
        } else {
            // No 4:3 format supported the requested framerate. Log and
            // fall through to the device default.
            #if DEBUG
            print("[CameraStore] No 4:3 format supports \(framerate.fps) fps; using device default.")
            #endif
        }
    }

    /// Pure 4:3-format selection helper. Filters `formats` to those whose
    /// `formatDescription` dimensions are within 0.01 of 4:3 and whose
    /// `videoSupportedFrameRateRanges` cover `preferredFPS`, then returns
    /// the highest-resolution match (by pixel area). Returns nil if no
    /// format qualifies — caller falls back to the device default.
    ///
    /// On the iPhone 17e simulator the front-camera reports formats at
    /// 4032×3024, 1920×1440, 1440×1080, and 960×720 (all 4:3 readouts).
    /// At 30 fps we land on 4032×3024; at 60 fps on whichever 4:3 format
    /// has 60 fps in its supported ranges (typically 1920×1440 or lower).
    nonisolated static func selectFourThreeFormat(
        from formats: [AVCaptureDevice.Format],
        preferredFPS: Double
    ) -> AVCaptureDevice.Format? {
        // Map each format to the (width, height, [(min, max)]) shape so
        // we can run the decision through the pure helper. We have to do
        // this two-pass to associate the chosen tuple back to its source
        // format; we keep parallel arrays.
        let summaries: [(format: AVCaptureDevice.Format, descriptor: FormatDescriptor)] = formats.map { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let ranges = format.videoSupportedFrameRateRanges.map { range in
                (min: range.minFrameRate, max: range.maxFrameRate)
            }
            return (format, FormatDescriptor(width: Int(dims.width), height: Int(dims.height), frameRateRanges: ranges))
        }
        guard let chosenIndex = pickFourThreeFormatIndex(
            descriptors: summaries.map { $0.descriptor },
            preferredFPS: preferredFPS
        ) else {
            return nil
        }
        return summaries[chosenIndex].format
    }

    /// Lightweight value-type description of an AVCaptureDevice.Format —
    /// only the fields that drive the 4:3 + framerate decision. Pure value
    /// type so tests can construct fake formats without AVFoundation.
    struct FormatDescriptor: Equatable, Sendable {
        let width: Int
        let height: Int
        let frameRateRanges: [(min: Double, max: Double)]

        static func == (lhs: FormatDescriptor, rhs: FormatDescriptor) -> Bool {
            guard lhs.width == rhs.width, lhs.height == rhs.height else { return false }
            guard lhs.frameRateRanges.count == rhs.frameRateRanges.count else { return false }
            for (l, r) in zip(lhs.frameRateRanges, rhs.frameRateRanges) {
                if l.min != r.min || l.max != r.max { return false }
            }
            return true
        }
    }

    /// Pure decision helper — returns the index of the 4:3 format that
    /// supports `preferredFPS` and has the highest pixel area, or nil if
    /// no format qualifies. Tests target this directly.
    nonisolated static func pickFourThreeFormatIndex(
        descriptors: [FormatDescriptor],
        preferredFPS: Double
    ) -> Int? {
        let target: Double = 4.0 / 3.0
        let candidates: [(index: Int, descriptor: FormatDescriptor)] = descriptors
            .enumerated()
            .compactMap { (index, d) in
                guard d.height > 0 else { return nil }
                let ratio = Double(d.width) / Double(d.height)
                guard abs(ratio - target) < 0.01 else { return nil }
                let coversFPS = d.frameRateRanges.contains { range in
                    preferredFPS >= range.min - 0.01 && preferredFPS <= range.max + 0.01
                }
                return coversFPS ? (index, d) : nil
            }
        return candidates.max { lhs, rhs in
            (lhs.descriptor.width * lhs.descriptor.height) <
            (rhs.descriptor.width * rhs.descriptor.height)
        }?.index
    }

    // MARK: - Persistence

    private func persistStyle() {
        Prefs.cameraStyle = style.rawValue
    }
}

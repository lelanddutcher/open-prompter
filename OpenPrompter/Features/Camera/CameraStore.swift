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

        // Resolve the user's fps target, then run the tiered selection.
        let framerate = RecordingFramerate(rawValue: Prefs.recordingFramerate) ?? .default
        let fps = Double(framerate.fps)
        guard let choice = Self.selectOpenGateFormat(
            from: device.formats,
            preferredFPS: fps
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
    /// - Step 2 (iOS 26+): if any candidate has a non-empty
    ///   `supportedDynamicAspectRatios`, pick the largest such format and
    ///   return it with a `dynamicAspect` of `.ratio1x1` if 1×1 is in the
    ///   list (full square sensor on iPhone 17), else the first declared
    ///   aspect.
    /// - Step 3 (fallback): pick the largest pixel-area candidate regardless
    ///   of aspect; return with `dynamicAspect = nil` so the caller skips
    ///   the iOS 26 reshape call.
    /// Returns nil if no format covers `preferredFPS`.
    nonisolated static func selectOpenGateFormat(
        from formats: [AVCaptureDevice.Format],
        preferredFPS: Double
    ) -> OpenGateChoice? {
        let summaries: [(format: AVCaptureDevice.Format, descriptor: FormatDescriptor)] = formats.map { format in
            Self.summarize(format)
        }
        guard let pick = pickOpenGateFormat(
            descriptors: summaries.map { $0.descriptor },
            preferredFPS: preferredFPS
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
    ///   2. If any candidate has `supportsDynamicAspectRatios == true`, pick
    ///      the largest such format. If 1×1 is in its declared list, return
    ///      `dynamicAspectRaw = "AVCaptureAspectRatio1x1"`; else the first
    ///      declared aspect.
    ///   3. Else pick the largest pixel-area candidate, `dynamicAspectRaw = nil`.
    nonisolated static func pickOpenGateFormat(
        descriptors: [FormatDescriptor],
        preferredFPS: Double
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

        // Step 2: dynamic-aspect-capable candidates win when present.
        let dynamic = candidates.filter { $0.descriptor.supportsDynamicAspectRatios }
        if let best = dynamic.max(by: byPixelArea) {
            // Prefer 1×1 (square sensor full readout) if declared; else the
            // first listed aspect (which iOS 26 also makes the default).
            let supported = best.descriptor.dynamicAspectRatios
            let oneByOne = "AVCaptureAspectRatio1x1"
            let aspect = supported.contains(oneByOne) ? oneByOne : supported.first
            return (best.index, aspect)
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

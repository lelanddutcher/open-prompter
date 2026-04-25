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
    func setStyle(_ new: CameraStyle) async {
        guard new != style else { return }

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
        await start()
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

    // MARK: - AVCaptureSession plumbing

    /// Configure inputs (front camera) and start the session. The blocking
    /// `startRunning()` runs on `sessionQueue`; we await its completion so
    /// the @MainActor caller can flip UI state once the session is live.
    /// `start()` is idempotent — re-entry while the session is already
    /// running is a no-op (`if !session.isRunning`).
    private func start() async {
        if suppressDeviceWork {
            isSessionRunning = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                self.configureInputsLocked()
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                Task { @MainActor in
                    self.isSessionRunning = self.session.isRunning
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
        }
    }

    // MARK: - Persistence

    private func persistStyle() {
        Prefs.cameraStyle = style.rawValue
    }
}

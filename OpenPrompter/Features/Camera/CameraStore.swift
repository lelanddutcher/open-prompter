//
//  CameraStore.swift
//  OpenPrompter
//
//  Owner of the AVCaptureSession. Knows the user's chosen `CameraStyle`,
//  whether the front or rear camera is selected, and the camera permission
//  status. Lifecycle:
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

    /// Front (true) or rear (false) camera. Persisted to
    /// `Prefs.cameraFacingFront`. Defaults to front — selfie creators are
    /// the dominant audience.
    private(set) var facingFront: Bool

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

    /// Currently-attached camera input (so we can swap it on facingFront flip
    /// without rebuilding the whole session). `nil` until `start()` succeeds.
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
        self.facingFront = Prefs.cameraFacingFront
        self.authorization = AVCaptureDevice.authorizationStatus(for: .video)
    }

    // MARK: - Mode transitions (the core state machine)

    /// User-initiated mode change from the chip or Settings. Triggers the
    /// permission prompt the first time we move to a non-`.off` mode. On
    /// denial, snaps back to `.off` and sets `pendingPermissionDeniedBanner`.
    func setStyle(_ new: CameraStyle) async {
        guard new != style else { return }

        if new == .off {
            await stop()
            style = .off
            persistStyle()
            return
        }

        // We're moving to .pip or .behind — make sure we have permission.
        let granted = await requestAccessIfNeeded()
        guard granted else {
            // Snap back to off; surface a one-shot banner for the UI to read.
            style = .off
            persistStyle()
            pendingPermissionDeniedBanner = true
            await stop()
            return
        }
        style = new
        persistStyle()
        await start()
    }

    /// Long-press chip gesture: front ↔ rear. No-op in `.off` because there
    /// is no live session to swap inputs on. Persists the new facing.
    func swapCamera() async {
        guard style != .off else {
            // Just persist the choice so re-entering pip uses the new camera.
            facingFront.toggle()
            Prefs.cameraFacingFront = facingFront
            return
        }
        facingFront.toggle()
        Prefs.cameraFacingFront = facingFront
        await reconfigureInput()
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

    /// Configure inputs (front or rear camera) and start the session. The
    /// blocking `startRunning()` runs on `sessionQueue`; we await its completion
    /// so the @MainActor caller can flip UI state once the session is live.
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

    /// Swap the camera input without tearing down the whole session — used
    /// by long-press to flip front/rear.
    private func reconfigureInput() async {
        if suppressDeviceWork { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                self.session.beginConfiguration()
                if let existing = self.currentInput {
                    self.session.removeInput(existing)
                    self.currentInput = nil
                }
                self.configureInputsLocked()
                self.session.commitConfiguration()
                continuation.resume()
            }
        }
    }

    /// Build and attach the camera input for the current `facingFront`. Must
    /// be called inside a `beginConfiguration` block (or equivalent — this
    /// is invoked from `start()` and `reconfigureInput()` both of which set
    /// up configuration brackets around the call).
    ///
    /// Resolves the desired camera position from the @MainActor-isolated
    /// `facingFront` via a synchronous helper, then attaches the matching
    /// `AVCaptureDeviceInput`.
    nonisolated private func configureInputsLocked() {
        let position = currentDesiredPositionLocked()
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: position
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

    /// Helper that resolves the desired camera position from the @MainActor-
    /// owned `facingFront`. Called from inside `sessionQueue` blocks; we use
    /// `DispatchQueue.main.sync` only here because the value is a single Bool
    /// that the main actor mutates atomically. Avoids capturing `self`'s
    /// state by value in two places.
    nonisolated private func currentDesiredPositionLocked() -> AVCaptureDevice.Position {
        var front = true
        if Thread.isMainThread {
            // Already on main — read directly (this happens in unit tests)
            front = MainActor.assumeIsolated { self.facingFront }
        } else {
            DispatchQueue.main.sync {
                front = MainActor.assumeIsolated { self.facingFront }
            }
        }
        return front ? .front : .back
    }

    // MARK: - Persistence

    private func persistStyle() {
        Prefs.cameraStyle = style.rawValue
    }
}

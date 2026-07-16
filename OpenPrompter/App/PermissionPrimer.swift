//
//  PermissionPrimer.swift
//  OpenPrompter
//
//  2.5.0 hotfix. Requests Camera, Microphone, and Speech-Recognition
//  authorization at app startup so the founder-promoted feature set
//  (in-app camera, recording, voice tracking) works from the first
//  prompter open without the user having to re-enable things in
//  Settings or play permission whack-a-mole.
//
//  Why startup-prime instead of in-context?
//
//  Voice tracking previously failed silently for users who installed
//  the app and tried voice mode before ever tapping camera or REC: the
//  microphone permission only fires through the recording session
//  flow (`AVAudioApplication.requestRecordPermission()` in
//  RecordingSession.requestMicrophone), so a voice-first user had no
//  mic auth, AVAudioEngine couldn't bind an input node, and the
//  recognizer received zero audio. Asking all three at launch removes
//  that cross-feature ordering trap.
//
//  Each request is a no-op if the user has already answered (denied
//  or granted) — iOS only shows the system prompt when the current
//  status is `.notDetermined`. Safe to call on every launch; we still
//  guard with our own `.notDetermined` check to avoid kicking the
//  framework awake when there's nothing to do.
//
//  Order matters for UX: Camera → Microphone → Speech. iOS queues
//  the prompts sequentially, and that order matches how a creator
//  thinks about the feature stack: "show me on screen → record me →
//  follow my voice."
//

import AVFoundation
import Speech

@MainActor
enum PermissionPrimer {
    /// Request Camera, Microphone, and Speech-Recognition authorization
    /// in sequence if any are still `.notDetermined`. Returns when all
    /// three system prompts (or no-ops) have completed.
    ///
    /// Already-granted or already-denied permissions are skipped silently —
    /// this method is safe to call on every cold launch.
    static func requestAllIfNeeded() async {
        await requestCameraIfNeeded()
        await requestMicrophoneIfNeeded()
        await requestSpeechRecognitionIfNeeded()
    }

    /// Start the camera session for a RETURNING user whose persisted
    /// `cameraStyle` is non-off. `CameraStore.init` reads the persisted
    /// style onto `self.style` but does NOT start the session — the session
    /// only starts on a user-initiated `setStyle(...)` (from the chip or the
    /// coach-mark "enable camera" button). Without this bootstrap, a user who
    /// left the camera on would re-enter to a PiP tile attached to a session
    /// that's `.style = .pip` but `isSessionRunning = false`, and would have
    /// to cycle the chip pip→off→pip to "fix" it.
    ///
    /// The registered default is `.off` (camera is opt-in — see
    /// `Prefs.cameraStyle`), so a fresh install no-ops here (the delegate's
    /// `style != .off` guard) and never auto-mounts a black PiP tile.
    ///
    /// Call this AFTER `requestAllIfNeeded()` so camera permission has
    /// been resolved before we try to start. Delegates to
    /// `CameraStore.bootstrapSessionForLaunchStyle()` which bypasses
    /// the same-style early-return in `setStyle`. No-op if the persisted
    /// style is already `.off`.
    @MainActor
    static func bootstrapCameraIfNeeded(_ store: CameraStore) async {
        await store.bootstrapSessionForLaunchStyle()
    }

    private static func requestCameraIfNeeded() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        default:
            break
        }
    }

    private static func requestMicrophoneIfNeeded() async {
        // iOS 17+ replaced AVAudioSession.requestRecordPermission with
        // AVAudioApplication.requestRecordPermission(). Project floor
        // is iOS 17 so we can use the new API directly without the
        // deprecation fallback ladder.
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            _ = await AVAudioApplication.requestRecordPermission()
        default:
            break
        }
    }

    private static func requestSpeechRecognitionIfNeeded() async {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in
                    continuation.resume()
                }
            }
        default:
            break
        }
    }
}

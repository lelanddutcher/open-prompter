//
//  RecordingState.swift
//  OpenPrompter
//
//  @Observable model that exposes the recording state machine to SwiftUI.
//  Feature 1 introduced this with a single `isRecording: Bool` flag for the
//  tally light. Feature 2 promotes it to a richer `phase: RecordingPhase`
//  but keeps `isRecording` as a computed property so the existing tally-
//  light wiring (and the Settings labs toggle) keeps working unchanged.
//
//  The model also carries:
//  - `elapsedSeconds` — derived from `phase == .recording(startedAt:)` and
//    refreshed by a `TimelineView` the chip subscribes to. The model writes
//    nothing here itself — it's a pure computed-from-phase value.
//  - `lastError` — most recent error string, surfaced via the banner in
//    AppState and cleared on the next non-error transition.
//  - `pendingSavedToast` — set when a save completes, consumed by the
//    prompter view to fire a brief "Saved to Photos" toast.
//

import Foundation
import Observation

@Observable
@MainActor
final class RecordingState {

    // MARK: - Phase

    /// The current state-machine phase. Setting this is the canonical way
    /// to advance the machine; SwiftUI updates the chip / countdown / Live
    /// Activity off this single source of truth.
    var phase: RecordingPhase = .idle

    /// True while the prompter is actively writing camera frames to disk.
    /// Computed off `phase` so a single `phase = .recording(...)` assignment
    /// drives the existing tally-light wiring without a separate setter.
    /// (Feature 1 callers — `TallyLightOverlay`, the Settings toggle —
    /// continue to read `isRecording` directly.)
    var isRecording: Bool {
        get { phase.isRecording }
        set {
            // Feature 1's labs toggle binds to this Boolean. Keep that
            // contract: writing `true` here flips us into a synthetic
            // recording phase (no real writer), writing `false` returns to
            // idle. Real recording sets `phase` directly via the
            // RecordingSession actor.
            if newValue, !isRecording {
                phase = .recording(startedAt: .now)
            } else if !newValue, isRecording {
                phase = .idle
            }
        }
    }

    /// Elapsed seconds since recording started. `0` outside of `.recording`.
    /// Re-read every second by the chip's `TimelineView`; we don't store a
    /// timer here — the phase carries the start date and the view computes.
    func elapsedSeconds(now: Date = .now) -> Int {
        guard case .recording(let startedAt) = phase else { return 0 }
        return max(0, Int(now.timeIntervalSince(startedAt)))
    }

    // MARK: - Saved toast / error surface

    /// One-shot flag the prompter view consumes to fire a "Saved to Photos"
    /// toast. Cleared via `consumeSavedToast()`.
    private(set) var pendingSavedToast: SavedToast? = nil

    /// One-shot iCloud-copy failure banner cue. Set by `RecordingSession`
    /// when the script-folder copy fails. The view consumes this and
    /// surfaces the immediate failure banner with copy from V2 Design 02
    /// review note 4. No retry queue, no parked files.
    private(set) var pendingICloudCopyFailure: String? = nil

    /// Pending "recover partial recording" banner cue, set by the launch-
    /// time recovery scan if a stale `.mov` was found in
    /// `Documents/Recordings/`. Consumed by the prompter / library view.
    private(set) var pendingRecoveryBanner: URL? = nil

    /// Most recent error message. Cleared on the next non-error transition.
    private(set) var lastError: String? = nil

    /// Outcome detail for the toast.
    struct SavedToast: Equatable {
        var photosWritten: Bool
        var scriptFolderWritten: Bool
        /// Convenience copy. Matches V2 Design 02 §"Finalizing".
        var displayText: String {
            switch (photosWritten, scriptFolderWritten) {
            case (true, true):  return "Saved to Photos and script folder"
            case (true, false): return "Saved to Photos"
            case (false, true): return "Saved next to script"
            case (false, false): return "Saved"
            }
        }
    }

    // MARK: - Mutators (called from RecordingSession or the labs toggle)

    /// Begin the countdown. `seconds` is the user-configured pre-roll. With
    /// `0` we skip straight to recording. The session uses this to seed
    /// the pre-roll display; the countdown ticks decrement via
    /// `tickCountdown()` on a 1Hz timer.
    func startCountdown(seconds: Int) {
        if seconds <= 0 {
            phase = .recording(startedAt: .now)
        } else {
            phase = .countdown(remaining: seconds)
        }
        lastError = nil
    }

    /// Decrement the countdown by 1 second. When the remaining count drops
    /// to zero we transition into the recording phase and seed the start
    /// date. Idempotent for non-countdown phases.
    func tickCountdown(now: Date = .now) {
        guard case .countdown(let remaining) = phase else { return }
        if remaining <= 1 {
            phase = .recording(startedAt: now)
        } else {
            phase = .countdown(remaining: remaining - 1)
        }
    }

    /// Cancel the countdown — the user tapped the chip / a hardware button
    /// during the pre-roll. Phase returns to idle. Recording was never
    /// started, so there's nothing to finalize.
    func cancelCountdown() {
        guard case .countdown = phase else { return }
        phase = .idle
    }

    /// Stop recording. The writer's finalize work runs in the session;
    /// this call only flips the phase so the UI shows a finalizing spinner.
    func enterFinalizing() {
        guard case .recording = phase else { return }
        phase = .finalizing
    }

    /// Move into the saving phase (Photos + optional iCloud copy). Saved
    /// destinations were captured at start-of-recording and travel here so
    /// the chip can label "Saving…" without re-reading prefs (a Settings
    /// flip mid-take must not change destination).
    func enterSaving(destinations: SaveDestinations) {
        phase = .saving(destinations: destinations)
    }

    /// Mark the take saved successfully. Caller sets which destinations
    /// succeeded so the toast can describe partial success cleanly.
    func finishSavingSuccessfully(photos: Bool, scriptFolder: Bool) {
        pendingSavedToast = SavedToast(
            photosWritten: photos,
            scriptFolderWritten: scriptFolder
        )
        phase = .idle
    }

    /// Surface a non-fatal iCloud-copy failure. The Photos write may have
    /// succeeded (Photos failure is its own error path) so the toast still
    /// fires for the half that worked.
    func surfaceICloudCopyFailure(reason: String, photosSucceeded: Bool) {
        pendingICloudCopyFailure = reason
        if photosSucceeded {
            pendingSavedToast = SavedToast(
                photosWritten: true,
                scriptFolderWritten: false
            )
        }
        phase = .idle
    }

    /// Surface a fatal error. The chip resets to idle once the user reads
    /// the banner; we don't latch the error phase forever.
    func surfaceError(_ message: String) {
        lastError = message
        phase = .error(message)
    }

    /// Clear an error after the user dismisses it. Returns to idle.
    func dismissError() {
        guard case .error = phase else { return }
        phase = .idle
    }

    /// Set the recovery-banner cue. Consumed via `consumeRecoveryBanner()`.
    func surfaceRecovery(url: URL) {
        pendingRecoveryBanner = url
    }

    // MARK: - One-shot consumers

    func consumeSavedToast() -> SavedToast? {
        defer { pendingSavedToast = nil }
        return pendingSavedToast
    }

    func consumeICloudCopyFailure() -> String? {
        defer { pendingICloudCopyFailure = nil }
        return pendingICloudCopyFailure
    }

    func consumeRecoveryBanner() -> URL? {
        defer { pendingRecoveryBanner = nil }
        return pendingRecoveryBanner
    }

    // MARK: - Backward-compat (Feature 1 labs toggle)

    /// Debug-only flip used by the tally-light Labs toggle in Settings (and
    /// by the existing CameraTests). Production callers shouldn't use this
    /// — the recording session writes `phase` directly via the mutators
    /// above.
    func toggleForDebug() {
        if isRecording {
            phase = .idle
        } else {
            phase = .recording(startedAt: .now)
        }
    }
}

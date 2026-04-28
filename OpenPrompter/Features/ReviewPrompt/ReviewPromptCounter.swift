//
//  ReviewPromptCounter.swift
//  OpenPrompter
//
//  Tracks the meaningful-engagement signals that gate the App Store
//  review prompt (Feature 8 of the v2 roadmap). Pure model — no UIKit /
//  StoreKit dependency, so the predicate is unit-testable without an
//  app context. The companion `ReviewPromptController` handles the
//  actual `SKStoreReviewController.requestReview(in:)` call.
//
//  Why we don't just call StoreKit on every launch:
//  iOS rate-limits review prompts to 3 per 365 days per Apple ID, and
//  Apple's review-prompt guidance is explicit that asking too early or
//  too often is a guideline violation (App Store Review §3.2). We also
//  don't get a callback telling us if the user actually saw the prompt
//  — the OS may suppress it for any reason — so the only correct
//  posture is "ask once per app version after demonstrated engagement,
//  let StoreKit decide the rest."
//

import Foundation
import Observation

/// Activity counters + thresholds that decide when an App Store review
/// prompt is appropriate. Backed by `UserDefaults` via the `Prefs` enum;
/// `@Observable` so a future Settings surface can show the user their
/// own activity (e.g. "you've recorded 12 takes" — purely informational).
@Observable
@MainActor
final class ReviewPromptCounter {

    // MARK: - Counters
    //
    // Mirror Prefs on construction so we can serve reads cheaply without
    // hitting UserDefaults every time. Writes go through the setters
    // below, which fan out to Prefs immediately so a force-quit doesn't
    // lose the increment.

    private(set) var recordingsCompleted: Int
    private(set) var playSessionsCompleted: Int
    private(set) var totalPlaybackSeconds: Double
    private(set) var firstLaunchAt: Date
    private(set) var lastPromptedAppVersion: String

    // MARK: - Init

    init() {
        self.recordingsCompleted = Prefs.reviewRecordingsCompleted
        self.playSessionsCompleted = Prefs.reviewPlaySessionsCompleted
        self.totalPlaybackSeconds = Prefs.reviewTotalPlaybackSeconds
        // `Prefs.reviewFirstLaunchAt` lazily initialises itself on first
        // read, so calling it here both fetches the stored value AND
        // stamps "now" if this is genuinely the user's first launch.
        self.firstLaunchAt = Prefs.reviewFirstLaunchAt
        self.lastPromptedAppVersion = Prefs.reviewLastPromptedAppVersion
    }

    // MARK: - Increments

    /// Called from `RecordingSession` after a successful Photos write.
    /// We don't count failed saves — those represent friction, not
    /// satisfaction.
    func recordSuccessfulRecording() {
        recordingsCompleted += 1
        Prefs.reviewRecordingsCompleted = recordingsCompleted
    }

    /// Called when a prompter playback session ends (pause, end-of-script,
    /// or view-disappear). `durationSeconds` is the elapsed playback time
    /// for that single session — sessions shorter than 30 s don't count
    /// because they're typically the user fiddling with controls, not
    /// reading. Cumulative playback seconds are still recorded so any
    /// future "total time read" surface stays accurate.
    func recordPlaySession(durationSeconds: Double) {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return }
        totalPlaybackSeconds += durationSeconds
        Prefs.reviewTotalPlaybackSeconds = totalPlaybackSeconds
        if durationSeconds >= 30 {
            playSessionsCompleted += 1
            Prefs.reviewPlaySessionsCompleted = playSessionsCompleted
        }
    }

    /// Called by `ReviewPromptController` immediately after a successful
    /// `requestReview(in:)` call. The OS may not have actually shown the
    /// prompt — Apple controls that — but we still mark the version so we
    /// don't burn the StoreKit rate-limit budget on retries.
    func markPrompted(forAppVersion version: String) {
        lastPromptedAppVersion = version
        Prefs.reviewLastPromptedAppVersion = version
    }

    // MARK: - Predicate

    /// Returns `true` when the user has demonstrated enough engagement
    /// AND we haven't already prompted in this app version AND ≥ 24 h
    /// have elapsed since first launch.
    ///
    /// The OR-of-thresholds design covers both major usage patterns:
    /// - **rig user** (records video) → `recordingsCompleted ≥ 1`
    /// - **read-along user** (no recording, lots of sessions) →
    ///   `playSessionsCompleted ≥ 3`
    ///
    /// Either path qualifies. Both, obviously, also qualify.
    ///
    /// Parameters:
    ///   - appVersion: the current `CFBundleShortVersionString`. We
    ///     compare against `lastPromptedAppVersion` so each new release
    ///     gets one fresh ask.
    ///   - now: injected for testability — defaults to wall-clock.
    func shouldRequestReview(
        appVersion: String,
        now: Date = .now
    ) -> Bool {
        // Don't ask on the day of install. Day-1 users are still figuring
        // the app out; an interruption is the wrong cost. 24 h is the
        // minimum cooldown.
        let hoursSinceFirstLaunch = now.timeIntervalSince(firstLaunchAt) / 3600
        guard hoursSinceFirstLaunch >= 24 else { return false }

        // Don't double-prompt within the same release. Apple's StoreKit
        // also rate-limits to 3 per 365 days per Apple ID, but that's
        // a global ceiling — we want to be far below it.
        guard !appVersion.isEmpty, lastPromptedAppVersion != appVersion else {
            return false
        }

        // Real engagement signal. Either path counts.
        let recordedAtLeastOnce = recordingsCompleted >= 1
        let playedEnoughSessions = playSessionsCompleted >= 3
        return recordedAtLeastOnce || playedEnoughSessions
    }

    // MARK: - DEBUG helpers

    #if DEBUG
    /// DEBUG-only reset for the Settings → Labs harness. Lets internal
    /// builds clear all review-prompt state to re-test the predicate
    /// without uninstalling the app or bumping the version.
    func debugReset() {
        recordingsCompleted = 0
        playSessionsCompleted = 0
        totalPlaybackSeconds = 0
        lastPromptedAppVersion = ""
        Prefs.reviewRecordingsCompleted = 0
        Prefs.reviewPlaySessionsCompleted = 0
        Prefs.reviewTotalPlaybackSeconds = 0
        Prefs.reviewLastPromptedAppVersion = ""
        // Note: we deliberately do NOT reset `firstLaunchAt` so the
        // 24 h gate stays meaningful in DEBUG runs.
    }
    #endif
}

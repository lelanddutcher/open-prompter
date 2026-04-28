//
//  ReviewPromptController.swift
//  OpenPrompter
//
//  Bridges `ReviewPromptCounter` → StoreKit. Pure orchestration: ask the
//  counter "is now a good time?", find the foreground `UIWindowScene`,
//  call `SKStoreReviewController.requestReview(in:)`, mark the counter
//  as prompted. Splitting this from the counter keeps the predicate
//  unit-testable without dragging UIKit / StoreKit into the test target.
//
//  StoreKit's `requestReview(in:)` may or may not actually show the
//  system prompt — Apple controls that based on the user's settings,
//  recent prompts across all apps, etc. We mark `lastPromptedAppVersion`
//  regardless, on the assumption that we tried; Apple's own rate limit
//  is the safety net that keeps us from over-prompting.
//

import StoreKit
import UIKit

@MainActor
enum ReviewPromptController {

    /// Check the counter's predicate against the current bundle version
    /// and, if appropriate, present the StoreKit review prompt. Safe to
    /// call from any foreground entry point — the counter's gates handle
    /// "not yet" gracefully.
    static func requestReviewIfAppropriate(counter: ReviewPromptCounter) {
        let appVersion = currentAppVersion()
        guard counter.shouldRequestReview(appVersion: appVersion) else { return }
        guard let scene = activeWindowScene() else { return }

        SKStoreReviewController.requestReview(in: scene)
        counter.markPrompted(forAppVersion: appVersion)
    }

    /// `CFBundleShortVersionString` from Info.plist (e.g. "1.0.0").
    /// Falls back to an empty string if the key is missing — the
    /// counter's predicate treats empty as "not a real version" and
    /// short-circuits, so we don't accidentally prompt on a corrupted
    /// build.
    private static func currentAppVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// Find the foreground-active `UIWindowScene`. StoreKit needs one to
    /// host its modal presentation. Returns `nil` if no scene is in the
    /// foreground (e.g. the app is being terminated) — the caller's
    /// `guard` short-circuits and the prompt is skipped, which is the
    /// safe behavior anyway.
    private static func activeWindowScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}

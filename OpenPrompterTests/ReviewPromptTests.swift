//
//  ReviewPromptTests.swift
//  OpenPrompterTests
//
//  Pins the App Store review-prompt predicate (Feature 8) to its spec:
//
//   - Don't ask in the first 24 h after install.
//   - Don't double-ask within the same `CFBundleShortVersionString`.
//   - Ask once the user has either recorded a take OR played ≥ 3
//     prompter sessions of ≥ 30 s each.
//   - Cumulative playback seconds tally regardless of session length.
//   - Sessions shorter than 30 s don't bump the session counter (but
//     their duration still rolls into total playback seconds, in case
//     a future surface wants the data).
//

import XCTest
@testable import OpenPrompter

@MainActor
final class ReviewPromptTests: XCTestCase {

    // MARK: - Test scaffolding

    /// Keys we mutate. Snapshotted at setUp + restored at tearDown so
    /// tests don't leak state across the suite.
    private let touchedKeys: [String] = [
        PrefKey.reviewRecordingsCompleted.rawValue,
        PrefKey.reviewPlaySessionsCompleted.rawValue,
        PrefKey.reviewTotalPlaybackSeconds.rawValue,
        PrefKey.reviewFirstLaunchAt.rawValue,
        PrefKey.reviewLastPromptedAppVersion.rawValue
    ]
    private var snapshot: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        let store = UserDefaults.standard
        snapshot.removeAll(keepingCapacity: true)
        for key in touchedKeys {
            snapshot[key] = store.object(forKey: key)
            store.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        let store = UserDefaults.standard
        for key in touchedKeys {
            if case let .some(value?) = snapshot[key] {
                store.set(value, forKey: key)
            } else {
                store.removeObject(forKey: key)
            }
        }
        snapshot.removeAll()
        super.tearDown()
    }

    // MARK: - Predicate

    /// The 24-hour grace period blocks any prompt regardless of activity.
    /// Day-1 users haven't had a chance to form an opinion yet.
    func testPredicateBlocksWithin24HoursOfFirstLaunch() {
        let counter = ReviewPromptCounter()
        // Force a recent first-launch stamp.
        Prefs.reviewFirstLaunchAt = .now
        let fresh = ReviewPromptCounter()
        // Even with engagement.
        fresh.recordSuccessfulRecording()

        XCTAssertFalse(
            fresh.shouldRequestReview(appVersion: "1.0.0"),
            "Day-1 install must never prompt, even with a recording in flight."
        )
        // Sanity: the counter actually saw the increment.
        XCTAssertEqual(fresh.recordingsCompleted, 1)
        _ = counter // keep the suite-level instance alive for tearDown
    }

    /// Past the 24-hour gate AND with at least one successful recording,
    /// the predicate fires.
    func testPredicateFiresAfterFirstRecordingPastGracePeriod() {
        Prefs.reviewFirstLaunchAt = Date(timeIntervalSinceNow: -25 * 3600)
        let counter = ReviewPromptCounter()
        counter.recordSuccessfulRecording()

        XCTAssertTrue(
            counter.shouldRequestReview(appVersion: "1.0.0"),
            "One recording past the 24 h gate must qualify."
        )
    }

    /// Read-along users (no recording) qualify after 3 ≥ 30 s sessions.
    func testPredicateFiresAfterThreeRealPlaySessions() {
        Prefs.reviewFirstLaunchAt = Date(timeIntervalSinceNow: -25 * 3600)
        let counter = ReviewPromptCounter()
        counter.recordPlaySession(durationSeconds: 60)
        counter.recordPlaySession(durationSeconds: 45)
        counter.recordPlaySession(durationSeconds: 90)

        XCTAssertEqual(counter.playSessionsCompleted, 3)
        XCTAssertTrue(
            counter.shouldRequestReview(appVersion: "1.0.0"),
            "Three real play sessions must qualify a non-recording user."
        )
    }

    /// Sessions shorter than 30 s must NOT bump the session counter even
    /// though their duration counts toward the total. Three 10 s
    /// sessions = 30 s total but zero "real" sessions.
    func testShortSessionsDoNotBumpSessionCount() {
        let counter = ReviewPromptCounter()
        counter.recordPlaySession(durationSeconds: 10)
        counter.recordPlaySession(durationSeconds: 12)
        counter.recordPlaySession(durationSeconds: 5)

        XCTAssertEqual(counter.playSessionsCompleted, 0,
                       "Sessions < 30 s must not be counted as 'real' sessions.")
        XCTAssertEqual(counter.totalPlaybackSeconds, 27, accuracy: 0.001,
                       "Total playback seconds still accumulate every session.")
    }

    /// Once we've prompted for an app version, we don't prompt again for
    /// that version regardless of additional engagement.
    func testPredicateSilentWhileAlreadyPromptedThisVersion() {
        Prefs.reviewFirstLaunchAt = Date(timeIntervalSinceNow: -25 * 3600)
        let counter = ReviewPromptCounter()
        counter.recordSuccessfulRecording()
        counter.markPrompted(forAppVersion: "1.0.0")

        XCTAssertFalse(
            counter.shouldRequestReview(appVersion: "1.0.0"),
            "Same version must not double-prompt."
        )
        XCTAssertTrue(
            counter.shouldRequestReview(appVersion: "1.1.0"),
            "A new release should re-qualify the user."
        )
    }

    /// Empty appVersion (defensive — shouldn't happen, Info.plist always
    /// has CFBundleShortVersionString) must NOT prompt: an empty string
    /// can't be compared meaningfully against `lastPromptedAppVersion`.
    func testPredicateSilentForMissingAppVersion() {
        Prefs.reviewFirstLaunchAt = Date(timeIntervalSinceNow: -25 * 3600)
        let counter = ReviewPromptCounter()
        counter.recordSuccessfulRecording()

        XCTAssertFalse(
            counter.shouldRequestReview(appVersion: ""),
            "Missing CFBundleShortVersionString must not trigger a prompt."
        )
    }

    /// User has zero engagement → predicate stays silent forever, no
    /// matter how long they've had the app installed.
    func testPredicateSilentWithoutEngagement() {
        Prefs.reviewFirstLaunchAt = Date(timeIntervalSinceNow: -100 * 24 * 3600)  // 100 days ago
        let counter = ReviewPromptCounter()

        XCTAssertFalse(
            counter.shouldRequestReview(appVersion: "1.0.0"),
            "A user who's never recorded or played a session must not be prompted."
        )
        // Two ≥ 30 s sessions still aren't enough — three are required.
        counter.recordPlaySession(durationSeconds: 60)
        counter.recordPlaySession(durationSeconds: 60)
        XCTAssertFalse(
            counter.shouldRequestReview(appVersion: "1.0.0"),
            "Two real sessions are below the 3-session threshold."
        )
    }

    // MARK: - Counter persistence

    func testCountersRoundTripThroughPrefs() {
        let first = ReviewPromptCounter()
        first.recordSuccessfulRecording()
        first.recordSuccessfulRecording()
        first.recordPlaySession(durationSeconds: 75)
        first.markPrompted(forAppVersion: "1.0.0")

        // Construct a fresh instance to prove state survives via Prefs.
        let second = ReviewPromptCounter()
        XCTAssertEqual(second.recordingsCompleted, 2)
        XCTAssertEqual(second.playSessionsCompleted, 1)
        XCTAssertEqual(second.totalPlaybackSeconds, 75, accuracy: 0.001)
        XCTAssertEqual(second.lastPromptedAppVersion, "1.0.0")
    }

    func testFirstLaunchAtPersistsAcrossInstances() {
        Prefs.reviewFirstLaunchAt = Date(timeIntervalSince1970: 1_700_000_000)
        let counter = ReviewPromptCounter()
        XCTAssertEqual(
            counter.firstLaunchAt.timeIntervalSince1970,
            1_700_000_000,
            accuracy: 1.0,
            "firstLaunchAt must survive across instances via Prefs."
        )
    }
}

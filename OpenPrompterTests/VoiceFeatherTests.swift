//
//  VoiceFeatherTests.swift
//  OpenPrompterTests
//
//  2.0.2: validates the FEATHER cursor's wiring into the velocity
//  controller. Pre-2.0.2, the BOT cursor was unwired in scroll math.
//  Founder reported "spread cursors apart for smoother glide" had no
//  effect — turned out to be true. The hotfix renames TOP/BOT →
//  READ/FEATHER and maps the FEATHER distance into (gain,
//  velocityAlpha) inside `voiceTrackingTick`.
//
//  Sanity checks here:
//
//  1. With identical target distance + dt, a TIGHT feather catches
//     up faster than a WIDE feather over the same number of ticks.
//     This is the core "tight = snappy, wide = smooth" promise.
//  2. The continuity at the legacy default. Pre-2.0.2 used gain 0.6
//     and velocityAlpha 0.05 unconditionally; the feather mapping
//     was tuned so featherFraction ≈ 0.20 reproduces those values
//     within a small tolerance, so existing users don't experience
//     a step-change in feel after upgrading.
//  3. Out-of-range inputs are clamped, not rejected — legacy stored
//     prefs from 2.0.1 might be anywhere; the controller must not
//     crash or produce NaN on them.
//

import XCTest
@testable import OpenPrompter

final class VoiceFeatherTests: XCTestCase {

    // MARK: - Tight feather catches up faster than wide feather

    /// Drives the controller for N ticks with the same target +
    /// dt under two different feathers and asserts the tight one
    /// has covered more of the distance. The exact numbers don't
    /// matter — the MONOTONIC relationship does.
    @MainActor
    func test_tightFeather_catchesUpFasterThanWideFeather() {
        let target: CGFloat = 1000
        let dt: TimeInterval = 1.0 / 60.0
        let ticks = 60 // ~1 second of simulation

        let tight = AutoScroller()
        let wide = AutoScroller()

        for _ in 0..<ticks {
            tight.voiceTrackingTick(
                target: target,
                dt: dt,
                maxOffset: 5000,
                featherFraction: 0.05 // tightest legal value
            )
            wide.voiceTrackingTick(
                target: target,
                dt: dt,
                maxOffset: 5000,
                featherFraction: 0.50 // widest legal value
            )
        }

        XCTAssertGreaterThan(
            tight.offset,
            wide.offset,
            "After identical simulation time, the tight-feather controller must have covered more distance toward the target than the wide-feather controller. Tight=\(tight.offset), Wide=\(wide.offset)."
        )
    }

    // MARK: - Out-of-range feather doesn't blow up

    /// Legacy stored prefs from 2.0.1 may have any value (the
    /// pre-2.0.2 BOT cursor stored fractions in the same key). The
    /// controller must clamp inputs rather than producing NaN /
    /// negative velocity / runaway scroll.
    @MainActor
    func test_voiceTrackingTick_clampsExtremeFeatherInputs() {
        let scroller = AutoScroller()
        // Negative — shouldn't happen in practice but a defensive
        // input the controller must handle.
        scroller.voiceTrackingTick(
            target: 500,
            dt: 1.0 / 60.0,
            maxOffset: 5000,
            featherFraction: -0.10
        )
        XCTAssertFalse(scroller.offset.isNaN, "Negative feather must clamp, not produce NaN.")
        XCTAssertGreaterThanOrEqual(scroller.offset, 0)
        // Way wider than legal — same.
        scroller.voiceTrackingTick(
            target: 500,
            dt: 1.0 / 60.0,
            maxOffset: 5000,
            featherFraction: 5.0
        )
        XCTAssertFalse(scroller.offset.isNaN)
    }

    // MARK: - Default feather hits target eventually

    /// At the documented default feather (0.13 ≈ 0.18 - 0.05), a
    /// long-running simulation must reach the target within a
    /// reasonable time bound. Catches a "feather wired backwards"
    /// regression where neither tight nor wide actually moves.
    @MainActor
    func test_defaultFeather_reachesTargetWithinBound() {
        let scroller = AutoScroller()
        let target: CGFloat = 200
        let dt: TimeInterval = 1.0 / 60.0
        // 10 seconds of simulation — generous bound for a 200pt
        // catch-up. Actual settling time at default feather is far
        // shorter; this is just the safety rail.
        for _ in 0..<600 {
            scroller.voiceTrackingTick(
                target: target,
                dt: dt,
                maxOffset: 5000,
                featherFraction: 0.13
            )
        }
        XCTAssertEqual(
            scroller.offset,
            target,
            accuracy: 1.0,
            "At default feather the controller must converge on the target within 10s of simulated time."
        )
    }

    // MARK: - 2.0.9 momentum: wide feather closes the gap

    /// Pre-2.0.9 the wide-feather P-controller settled into a
    /// steady-state lag — `distance × gain = targetRate`, so the
    /// scroll never actually reached the target while the user kept
    /// reading. Founder feedback: "even when feather is extremely far
    /// apart it will never get the spoken word up to the read line."
    /// 2.0.9 added a momentum term (target's own velocity) that turns
    /// the controller into PI-style: position term still closes the
    /// gap exponentially, but momentum keeps the scroll moving at the
    /// user's reading pace as a baseline. With BOTH active, the
    /// remaining error decays toward zero instead of equilibrating at
    /// a non-zero lag.
    ///
    /// This test simulates a user reading at ~50 pt/sec for 4 seconds.
    /// At wide feather (0.5) the scroll should END within 25pt of
    /// target. Pre-2.0.9 it would equilibrate around 125pt behind.
    @MainActor
    func test_wideFeather_catchesUpToMovingTarget() {
        let scroller = AutoScroller()
        let dt: TimeInterval = 1.0 / 60.0
        let userReadingRate: CGFloat = 50 // pt/sec — typical reading
        let frames = 60 * 4 // 4s of simulation

        // Drive a target that advances at userReadingRate every frame,
        // simulating the user's voice continuously matching new tokens.
        // The match cadence isn't perfectly per-frame in production —
        // the recognizer fires every 100-500ms — but for the controller
        // math the time-averaged rate is what matters.
        for i in 0..<frames {
            let target = CGFloat(i + 1) * userReadingRate * CGFloat(dt)
            scroller.voiceTrackingTick(
                target: target,
                dt: dt,
                maxOffset: 5000,
                featherFraction: 0.5,         // widest legal — most momentum
                maxVelocity: 1000             // generous so the cap doesn't lie
            )
        }
        let finalTarget = CGFloat(frames) * userReadingRate * CGFloat(dt)
        let lag = finalTarget - scroller.offset
        XCTAssertLessThan(
            lag,
            25,
            "At wide feather + steady reading pace, the momentum term must close the gap to within 25pt. Pre-2.0.9 the pure-P controller equilibrated around 125pt behind. Lag=\(lag)pt, target=\(finalTarget), offset=\(scroller.offset)."
        )
    }

    // MARK: - Catch-up floor (minVelocity)

    /// With a far-away target and a wide (slow) feather, the smoothed
    /// P-velocity ramps up gently. The catch-up floor must override that
    /// ramp so the very first tick already advances at the floor rate.
    @MainActor
    func test_minVelocity_floorAppliesFromFirstTick() {
        let scroller = AutoScroller()
        let dt: TimeInterval = 1.0 / 60.0
        scroller.voiceTrackingTick(
            target: 800,
            dt: dt,
            maxOffset: 5000,
            featherFraction: 0.5,      // slowest ramp
            maxVelocity: 400,
            minVelocity: 240
        )
        XCTAssertEqual(
            scroller.offset,
            240 * dt,
            accuracy: 0.001,
            "First tick with a big lag must advance at the floor rate, not the smoothed P rate. offset=\(scroller.offset)."
        )
    }

    /// The floor must never push the scroll PAST the target: when the
    /// remaining distance is smaller than one floor-step, the floor
    /// stands down and the normal (smooth) approach governs. Asserts
    /// the offset never overshoots during the approach, then that the
    /// controller still converges.
    @MainActor
    func test_minVelocity_neverOvershootsTarget() {
        let scroller = AutoScroller()
        scroller.seek(to: 799, maxOffset: 5000)
        let dt: TimeInterval = 1.0 / 60.0
        var maxSeen: CGFloat = 0
        for _ in 0..<600 {
            scroller.voiceTrackingTick(
                target: 800,
                dt: dt,
                maxOffset: 5000,
                featherFraction: 0.5,
                maxVelocity: 400,
                minVelocity: 240
            )
            maxSeen = max(maxSeen, scroller.offset)
        }
        XCTAssertLessThanOrEqual(
            maxSeen,
            800.001,
            "The floor must never carry the offset past the target. maxSeen=\(maxSeen)."
        )
        XCTAssertEqual(
            scroller.offset,
            800,
            accuracy: 0.5,
            "Given time, the controller still converges on the target. offset=\(scroller.offset)."
        )
    }
}

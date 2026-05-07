//
//  AutoScroller.swift
//  OpenPrompter
//
//  Pure time-integration math for the teleprompter's auto-scroll. No SwiftUI
//  here — this type is unit-testable and deterministic. The view layer
//  feeds it tick times and speed values, and the AutoScroller returns how
//  many points to advance since the last tick.
//

import Foundation

@Observable
@MainActor
final class AutoScroller {
    /// The last Date we integrated. Reset when playback pauses.
    private var lastTick: Date?

    /// Total accumulated scroll offset in points.
    private(set) var offset: CGFloat = 0

    /// Set when playback ends (end of script reached). View can observe to
    /// flip the play button back to paused state.
    private(set) var didReachEnd: Bool = false

    /// Internal velocity state for voice tracking — not part of the
    /// auto-scroll path. Updated by `voiceTrackingTick`. Persists
    /// across ticks so the velocity low-pass smoothing carries over.
    private var voiceVelocity: CGFloat = 0

    func reset() {
        lastTick = nil
        offset = 0
        didReachEnd = false
    }

    func resetTick() {
        lastTick = nil
    }

    /// Integrate time since the previous tick and return the delta in points.
    /// Returns 0 on the first tick (baseline) and when dt is negative or
    /// unreasonably large (handles clock jumps / app resumes).
    func advance(now: Date, speed: Double) -> CGFloat {
        defer { lastTick = now }
        guard let last = lastTick else { return 0 }
        let dt = now.timeIntervalSince(last)
        guard dt > 0, dt < 1.0 else { return 0 } // clamp absurd dt from resume/throttle
        return CGFloat(max(0, speed) * dt)
    }

    /// Add a delta to the running offset and clamp against content bounds.
    /// Call this after advance() with the returned delta.
    func apply(delta: CGFloat, maxOffset: CGFloat) {
        offset += delta
        if offset < 0 {
            offset = 0
        } else if offset >= maxOffset {
            offset = maxOffset
            didReachEnd = true
        }
    }

    /// Manual seek (used by jump-forward / jump-backward and restart).
    func seek(to newOffset: CGFloat, maxOffset: CGFloat) {
        offset = min(max(0, newOffset), maxOffset)
        didReachEnd = offset >= maxOffset
        lastTick = nil
    }

    /// Per-frame velocity-controlled scroll toward `target`. Used by
    /// voice tracking to feel like a constant smooth scroll rather
    /// than a sequence of catch-up lerps.
    ///
    /// Model: a proportional controller computes desired velocity from
    /// distance-to-target, then the actual `voiceVelocity` low-pass
    /// filters toward that. Result is smooth acceleration AND smooth
    /// deceleration — no per-tick lurches even when the target jumps a
    /// long way after a 500ms recognizer gap. Velocity caps at
    /// `maxVelocity` (pt/sec) so the experience stays comfortable
    /// regardless of how far behind the cursor is.
    ///
    /// - `target`: scroll offset the user "should" be at, derived from
    ///   the matched-word position and the READ-line fraction.
    /// - `dt`: time since last tick. Framerate-independent.
    /// - `featherFraction`: the gap between the READ cursor (top) and
    ///   the FEATHER cursor (bottom) on screen, in [0, 1] of viewport
    ///   height. Drives the (gain, velocityAlpha) pair on a single
    ///   axis the user can dial in their UI:
    ///     • Small feather (cursors close together) → snappy controller,
    ///       cursor catches up fast, feels in-sync.
    ///     • Wide feather (cursors spread apart) → looser controller,
    ///       smoother momentum, cursor glides toward target.
    ///   Pre-2.0.2 the `voiceBoxBottomFraction` did nothing in the
    ///   scroll math; the user-visible "spread cursors apart for
    ///   smoother glide" intuition went unsatisfied. This parameter
    ///   wires the BOT (now FEATHER) cursor into actual behavior.
    /// - `maxVelocity`: hard ceiling on scroll velocity in pt/sec.
    func voiceTrackingTick(
        target: CGFloat,
        dt: TimeInterval,
        maxOffset: CGFloat,
        featherFraction: CGFloat = 0.13,
        maxVelocity: CGFloat = 200
    ) {
        let clampedTarget = min(max(0, target), maxOffset)
        let distance = clampedTarget - offset

        // 2.0.4 snap zone: at the minimum legal feather (~0.05 — the
        // drag-handle clamp's floor), bypass the lerp entirely and
        // place scroll at target. The user explicitly asked for
        // "near-instant" follow when READ + FEATHER are stacked, and
        // the velocity-controlled path can't deliver sub-100ms catch-
        // up no matter how hard we crank gain. Threshold is the
        // clamp floor + a small epsilon so this fires when the user
        // is clearly at "tight" but doesn't trigger on accidental
        // wobble during a drag.
        if featherFraction <= 0.06 {
            offset = clampedTarget
            voiceVelocity = 0
            if offset >= maxOffset { didReachEnd = true }
            return
        }

        // Map feather fraction → (gain, velocityAlpha). The clamp
        // mirrors the drag-handle clamps in VoiceTrackingOverlayLayer
        // (READ and FEATHER can't be closer than 0.05 or further
        // than ~0.5 apart). Out-of-range inputs are clamped, not
        // rejected, so legacy stored prefs from 2.0.1 stay valid.
        let f = max(0.05, min(0.5, featherFraction))
        let normalized = (f - 0.05) / (0.5 - 0.05) // 0..1
        // Snappy at low feather (gain ~0.9, velocityAlpha ~0.15) and
        // smooth at high feather (gain ~0.4, velocityAlpha ~0.02). The
        // ranges were picked empirically to match the prior default
        // (gain 0.6, velocityAlpha 0.05) at roughly featherFraction
        // 0.20 — so users who never touch the cursors get the same
        // feel they had before this refactor.
        let gain: CGFloat = 0.9 - normalized * 0.5
        let velocityAlpha: CGFloat = 0.15 - normalized * 0.13

        // P-controller: velocity proportional to distance, clamped.
        let desiredVelocity = max(-maxVelocity, min(maxVelocity, distance * gain))

        // Low-pass on velocity to smooth acceleration.
        voiceVelocity = voiceVelocity * (1 - velocityAlpha)
                      + desiredVelocity * velocityAlpha

        // Integrate position.
        let proposed = offset + voiceVelocity * CGFloat(dt)
        offset = min(maxOffset, max(0, proposed))

        // Settle when we're effectively at target AND moving slowly so
        // the controller doesn't jitter forever near the asymptote.
        if abs(distance) < 0.5 && abs(voiceVelocity) < 2 {
            offset = clampedTarget
            voiceVelocity = 0
        }
        if offset >= maxOffset { didReachEnd = true }
    }

    /// Reset voice-tracking velocity state. Call when voice tracking
    /// stops so a future activation starts from a known zero.
    func resetVoiceVelocity() {
        voiceVelocity = 0
    }
}

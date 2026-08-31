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

    /// 2.0.9: tracking the target's OWN velocity (reading pace) so
    /// wide-feather mode can carry momentum instead of settling into
    /// a steady-state lag behind the user. Updated only when the
    /// target actually changes (a new match arrived) — frame-by-frame
    /// updates with unchanged target would decay the estimate to zero.
    /// `nil` until first update so we don't compute a bogus delta on
    /// the very first match.
    ///
    /// Time tracking uses the `dt` accumulator (`voiceTimeAccumulator`)
    /// rather than `ProcessInfo.systemUptime` so simulated-time tests
    /// produce matching velocity estimates — an earlier draft that
    /// read wall-clock time computed targetVelocity from real elapsed
    /// while the controller integrated offset against simulated `dt`,
    /// and the two diverged dramatically in unit tests.
    private var lastTargetForVelocity: CGFloat?
    private var lastTargetTimeForVelocity: TimeInterval = 0
    private var targetVelocity: CGFloat = 0
    private var voiceTimeAccumulator: TimeInterval = 0

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
    /// - `minVelocity`: forward catch-up floor in pt/sec (0 = off). When
    ///   the acknowledged word lags far below the READ line, the pure
    ///   P-controller crawls asymptotically; the view passes a floor so
    ///   the chase covers ground briskly. Applied AFTER the low-pass, so
    ///   it responds on frame 1, and only while `distance > 0` (never
    ///   pushes backward or past the target — the clamp below still
    ///   governs).
    /// Catch-up floor for voice follow, as a pure function so it can be
    /// tested without standing up a View.
    ///
    /// `lag` is how far the acknowledged word sits BELOW the READ line. The
    /// floor ramps in from zero once the lag passes `halfway` (the midpoint
    /// between READ and mid-screen) and reaches 60% of `maxVelocity` a quarter
    /// of a viewport later.
    ///
    /// `halfway` is clamped at zero on purpose. It is derived as
    /// `viewportHeight/2 - readY`, which goes NEGATIVE once the user drags the
    /// READ line past mid-screen (it is draggable to 0.95). Unclamped, that
    /// makes the ramp start below zero lag — pinning the floor on permanently
    /// and replacing the gentle P-controller with a constant chase for anyone
    /// who prefers a low READ line.
    nonisolated static func catchUpFloor(
        lag: CGFloat,
        readY: CGFloat,
        viewportHeight: CGFloat,
        maxVelocity: CGFloat
    ) -> CGFloat {
        guard viewportHeight > 0 else { return 0 }
        let halfway = max(0, viewportHeight * 0.5 - readY)
        guard lag > halfway else { return 0 }
        let urgency = min(1, (lag - halfway) / (viewportHeight * 0.25))
        return maxVelocity * 0.6 * urgency
    }

    func voiceTrackingTick(
        target: CGFloat,
        dt: TimeInterval,
        maxOffset: CGFloat,
        featherFraction: CGFloat = 0.13,
        maxVelocity: CGFloat = 200,
        minVelocity: CGFloat = 0
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
            // Reset momentum tracking too — next time the user widens
            // feather we want a fresh estimate, not a stale one from
            // before the snap.
            lastTargetForVelocity = nil
            lastTargetTimeForVelocity = 0
            targetVelocity = 0
            voiceTimeAccumulator = 0
            if offset >= maxOffset { didReachEnd = true }
            return
        }

        // 2.0.9: track the target's own velocity (the user's reading
        // pace in pt/sec) ONLY when it actually changes. This is what
        // turns the controller from pure P → effectively PI, letting
        // wide-feather mode catch up to READ instead of sitting in a
        // steady-state lag. Pre-2.0.9 wide feather settled into
        // `distance × gain = targetRate`, i.e. permanent lag of
        // `targetRate / gain` ≈ 125pt at typical reading speed.
        // Founder feedback: "even when feather is extremely far apart
        // it will never get the spoken word up to the read line — it
        // doesn't carry any continuous speed to do so."
        voiceTimeAccumulator += dt
        let now = voiceTimeAccumulator
        if let lastT = lastTargetForVelocity {
            let delta = clampedTarget - lastT
            // Only sample when the target moved (a new match arrived
            // and shifted it). Per-frame ticks with unchanged target
            // would decay the estimate to zero against `delta = 0`.
            if abs(delta) > 0.5 {
                let elapsed = now - lastTargetTimeForVelocity
                if elapsed > 0.001 {
                    let estimate = delta / CGFloat(elapsed)
                    // Smooth the estimate — match cadence is irregular
                    // (recognizer fires every 100-500ms), raw deltas
                    // are noisy. 0.4 alpha trades responsiveness for
                    // stability.
                    targetVelocity = targetVelocity * 0.6 + estimate * 0.4
                }
                lastTargetForVelocity = clampedTarget
                lastTargetTimeForVelocity = now
            }
        } else {
            lastTargetForVelocity = clampedTarget
            lastTargetTimeForVelocity = now
        }

        // Map feather fraction → (gain, velocityAlpha, momentumWeight).
        // The clamp mirrors the drag-handle clamps in
        // VoiceTrackingOverlayLayer (READ and FEATHER can't be closer
        // than 0.05 or further than ~0.5 apart). Out-of-range inputs
        // are clamped, not rejected, so legacy stored prefs from 2.0.1
        // stay valid.
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
        // Momentum weight: 0 at tight feather (pure P-controller), 1 at wide
        // feather (full reading-pace baseline + position correction). The
        // blend gives "wider feather = momentum sensation" and lets a wide
        // feather keep pace with CONTINUOUS reading (2.0.9 — needed so the
        // spoken word reaches the read line instead of equilibrating ~125pt
        // behind). The "constant playback" the founder saw is a PAUSE
        // overshoot, addressed by the faster momentum decay below + the 1.0s
        // silence-halt — NOT by weakening this term, which would reintroduce
        // the wide-feather steady-state lag (VoiceFeatherTests guards it).
        let momentumWeight = normalized

        // 2.0.10 momentum decay: bleed `targetVelocity` so a mid-sentence
        // pause doesn't keep the prompter rolling (silence-halt at 1.0s in
        // TeleprompterView is the hard backstop; this soft decay settles the
        // coast BEFORE that, so a breath between phrases doesn't read as
        // "constant playback" — dogfood feedback). Sped up from half-life
        // ~0.7s (0.371) to ~0.43s (0.20). Continuous reading re-samples
        // `targetVelocity` on every match, so keep-pace is intact (the
        // per-frame moving-target test still converges); only genuine pauses,
        // where no new match refreshes it, feel the faster bleed.
        let perSecondDecay: CGFloat = 0.20
        let frameDecay = pow(perSecondDecay, CGFloat(dt))
        targetVelocity *= frameDecay

        // 2.0.10 architecture change: split the velocity into TWO
        // components and integrate them independently.
        //
        //   • `momentumComponent` is applied DIRECTLY to offset every
        //     frame — no lerp. This is the "carry the prompter at the
        //     reading pace" piece, and pre-2.0.10 it went through the
        //     same low-pass as the position term. Result: voiceVel had
        //     to ramp from 0 to ~targetVel over ~1s every time the
        //     scroll briefly settled, which felt like "comes to a stop
        //     and slowly restarts." Now the momentum responds frame-1.
        //
        //   • `voiceVelocity` is JUST the smoothed position correction
        //     (`distance × gain` low-passed). This piece needs the
        //     smoothing — without it the controller would jitter on
        //     small distance noise.
        //
        // Combined offset advance per frame:
        //   offset += (momentumComponent + voiceVelocity) × dt
        //
        // Cap the combined velocity so a runaway momentum + correction
        // sum can't exceed maxVelocity.
        let momentumComponent = targetVelocity * momentumWeight
        let pVelocity = distance * gain
        voiceVelocity = voiceVelocity * (1 - velocityAlpha)
                      + pVelocity * velocityAlpha
        var combinedVel = max(-maxVelocity, min(maxVelocity, momentumComponent + voiceVelocity))

        // Catch-up floor: when the acknowledged word sits far below READ,
        // the smoothed P-velocity is deliberately small near the target —
        // great for landing softly, terrible for recovering a big lag.
        // The floor overrides the smoothing (frame-1 response) but never
        // the ceiling, and only applies while chasing forward. Gated on
        // `distance > minVelocity × dt` so a floor step can never overshoot
        // the target and oscillate around it.
        if minVelocity > 0, distance > minVelocity * CGFloat(dt) {
            combinedVel = max(combinedVel, min(minVelocity, maxVelocity))
        }

        // Integrate position.
        let proposed = offset + combinedVel * CGFloat(dt)
        offset = min(maxOffset, max(0, proposed))

        // Settle when we're effectively at target AND nothing's pulling
        // us forward. Crucially: only settle when momentum is also
        // negligible — otherwise a wide-feather coast would zero out
        // mid-glide and need to ramp back from 0 on the next match.
        // Pre-2.0.10 this was the "stop and restart" feel between
        // matches that the user reported as the prompter "coming to a
        // complete stop very quickly."
        if abs(distance) < 0.5
            && abs(voiceVelocity) < 2
            && abs(momentumComponent) < 2 {
            offset = clampedTarget
            voiceVelocity = 0
            targetVelocity = 0
        }
        if offset >= maxOffset { didReachEnd = true }
    }

    /// Reset voice-tracking velocity state. Call when voice tracking
    /// stops so a future activation starts from a known zero. Also
    /// clears the 2.0.9 momentum-tracking estimate so silence-halt
    /// doesn't leave a stale targetVelocity that would resume scrolling
    /// at the previous reading pace before any new matches arrive.
    func resetVoiceVelocity() {
        voiceVelocity = 0
        lastTargetForVelocity = nil
        lastTargetTimeForVelocity = 0
        targetVelocity = 0
        voiceTimeAccumulator = 0
    }
}

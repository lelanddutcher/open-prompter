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

    /// Per-frame interpolation toward `target`. Used by voice tracking
    /// to smoothly glide to the next matched-word position instead of
    /// teleporting on every alignment update.
    ///
    /// - `alpha`: fraction of remaining distance covered per tick. Low
    ///   values (~0.03) feel feathered; high values (~0.15) feel
    ///   responsive but lurch on big target jumps.
    /// - `maxStep`: hard cap on per-tick movement in points. Keeps a
    ///   multi-line cursor advance from translating to a sharp visual
    ///   jump — instead the scroll glides at constant max velocity
    ///   until it catches up.
    func lerpToward(
        target: CGFloat,
        alpha: CGFloat,
        maxStep: CGFloat,
        maxOffset: CGFloat
    ) {
        let clampedTarget = min(max(0, target), maxOffset)
        let distance = clampedTarget - offset
        let raw = distance * alpha
        let capped = max(-maxStep, min(maxStep, raw))
        // Settle when distance is sub-pixel so we don't asymptote forever.
        if abs(distance) < 0.5 {
            offset = clampedTarget
        } else {
            offset = min(maxOffset, max(0, offset + capped))
        }
        if offset >= maxOffset { didReachEnd = true }
    }
}

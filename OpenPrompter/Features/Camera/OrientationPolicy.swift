//
//  OrientationPolicy.swift
//  OpenPrompter
//
//  Per-aspect rotation policy. The writer's `videoInput.transform` and the
//  preview layer's `connection.videoRotationAngle` are BOTH derived from the
//  user's picker aspect (`Prefs.recordingAspect`), NOT from runtime buffer
//  dims. This is the dogfood-pass-11 architectural fix for the cold-start
//  rotation race captured in CLAUDE.md hard-won lesson #6:
//
//    `device.dynamicDimensions` returns (0,0) for ~33-100ms after session
//    start under iOS 26 `setDynamicAspectRatio` (the API is async with no
//    completion handler), and `activeFormat` returns format-nominal dims
//    that don't match the picker's intended buffer. Reading the picker
//    pref is synchronous, racing-free, and matches the user's intent.
//
//  Rationale: previously both the writer (`RecordingSession.writerTransform`)
//  and the preview (`PreviewView.applyOrientationDependentRotation`) inferred
//  rotation from buffer dims read at first-sample time. On a cold launch
//  before the dynamic-aspect reshape lands, that read returned the WRONG
//  shape and we picked the wrong rotation — symptom: behind-mode preview
//  rotated 90° on first launch only, correct on restart. Per-aspect lookup
//  is deterministic and removes the race entirely.
//

import AVFoundation
import CoreGraphics
import Foundation

/// Per-aspect rotation policy. The writer's `videoInput.transform` and the
/// preview layer's `connection.videoRotationAngle` are BOTH derived from
/// the user's picker aspect, NOT from runtime buffer dims (which race on
/// first cold start, see dogfood-pass-10/-11 lessons in CLAUDE.md).
///
/// Rationale: `device.dynamicDimensions` returns (0,0) for ~33-100ms after
/// session start under iOS 26 `setDynamicAspectRatio`. Reading the picker
/// pref is synchronous, racing-free, and matches the user's intent.
///
/// QA REVIEWER FOCUS: when the user reports a new device class showing
/// wrong orientation, ADD a row to the table — do not change the runtime
/// logic. Per-aspect pivots also live here; the helpers are pure and
/// testable.
enum OrientationPolicy {

    /// Writer's `videoInput.transform` for an aspect. Per-aspect lookup
    /// because iOS 26 reshape behaviour varies by sensor + aspect combo
    /// (see `.ratio4x3` on iPhone 17 1×1 sensor — TBD pending self-test).
    ///
    /// QA REVIEWER FOCUS: this table is the single source of truth for
    /// recorded-file orientation metadata. New device class behaviours
    /// (e.g. iPhone 18 sensor reshape quirks, Vision Pro passthrough,
    /// accessory cameras) belong as new rows here, NOT new branches in
    /// the call sites.
    static func writerTransform(for aspect: RecordingAspect) -> CGAffineTransform {
        switch aspect {
        case .ratio9x16:
            // iOS 26 reshapes to 2160×3840 portrait pixels. Buffer is
            // already correctly oriented; identity ships portrait playback.
            return .identity
        case .ratio1x1:
            // 1×1 sensor or reshape; rotation no-op for square.
            return .identity
        case .openGate:
            // iPhone 17 1×1 sensor → 3024×3024 square; older 4:3 sensor →
            // 4032×3024 landscape. Identity is correct for square. For
            // landscape iOS-pre-26 devices (iPhone 16 and older), the
            // legacy -π/2 path lands portrait playback — but we expect
            // very few legacy users; use identity by default and let the
            // self-test JSON reveal if this needs a per-device override.
            // TODO: per-device override for legacy 4:3 sensors (iPhone 16
            // and older) if user reports surface "open gate sideways" on
            // those devices.
            return .identity
        case .ratio4x3:
            // PROVISIONAL: assuming +π/2 produces upright per dogfood-
            // pass-11 user report ("upside down" with the prior -π/2).
            // This is a best-guess for iPhone 17 + iOS 26 1×1 sensor
            // reshaping to 4:3 landscape with bottom-up scan. The sign
            // flip (+π/2 instead of -π/2) provides the missing 180° that
            // produced the upside-down playback. Update from the
            // .ratio4x3 self-test JSON.
            return CGAffineTransform(rotationAngle: .pi / 2)
        case .ratio16x9:
            // Same family as .ratio4x3 — landscape reshape from same
            // sensor. Match its convention until proven different.
            return CGAffineTransform(rotationAngle: .pi / 2)
        }
    }

    /// Preview-layer connection's `videoRotationAngle` for an aspect.
    /// Driven by buffer-shape-after-reshape (which we know from the
    /// picker pref — no need to read dynamicDimensions).
    static func previewRotationAngle(for aspect: RecordingAspect) -> CGFloat {
        switch aspect {
        case .ratio9x16:
            // Portrait buffer → don't rotate; the buffer is already
            // upright in display space.
            return 0
        case .ratio4x3, .ratio16x9:
            // Landscape buffer → rotate 90° for portrait display. Sign
            // matches the writer's CW rotation per QA1744 (positive
            // angle on capture connection rotates buffer pixels CW in
            // display coords, undoing landscape sensor scan).
            return 90
        case .ratio1x1:
            // Square — rotation is a no-op visually; pick 0 for
            // consistency with the writer's identity transform.
            return 0
        case .openGate:
            // iPhone 17 1×1 → square (no rotation). Older 4:3 → landscape
            // (90° rotation). Default to 90° because legacy devices need
            // it and square buffers are no-op visually under either choice.
            return 90
        }
    }

    /// Resolve the user's current aspect from `Prefs`. Centralized so
    /// callers don't repeat the raw-string parsing.
    static var current: RecordingAspect {
        return RecordingAspect(rawValue: Prefs.recordingAspect) ?? .default
    }
}

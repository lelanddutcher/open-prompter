//
//  OrientationPolicy.swift
//  OpenPrompter
//
//  Per-buffer-shape rotation policy. The writer's `videoInput.transform` and
//  the preview layer's `connection.videoRotationAngle` both derive from
//  TWO inputs:
//    1. The user's picker aspect (`Prefs.recordingAspect`) — drives playback
//       INTENT (portrait for 9:16/4:3/1:1/openGate, landscape for 16:9).
//    2. The actual buffer shape (portrait/landscape/square) — read from the
//       sample buffer dims (writer side) or the requested dynamic-aspect raw
//       (preview side, race-free).
//
//  Why this rewrite (post-pass-12):
//  The pass-11 policy was keyed only on aspect, but iOS 26.3.1 on iPhone 17
//  Pro Max does NOT expose `ratio1x1` in the front camera's
//  `supportedDynamicAspectRatios`. So when the user picks `openGate`, the
//  format selector falls back to `ratio4x3`, producing a 4032×3024 LANDSCAPE
//  buffer. The pass-11 policy returned identity for openGate (assuming a
//  square buffer), giving landscape playback — confirmed by self-test
//  2026-05-04T02:50Z.
//
//  The fix: derive rotation from buffer shape AND aspect intent, not just
//  aspect. A landscape buffer with portrait-intent aspect gets +π/2 rotation;
//  a portrait or square buffer with portrait-intent gets identity. This
//  handles ALL fallbacks correctly:
//    - iPhone 17 + ratio1x1 declared (future iOS): square buffer, identity, square playback ✓
//    - iPhone 17 + ratio4x3 fallback (current iOS 26.3.1): landscape buffer, +π/2, portrait playback ✓
//    - Legacy 4:3 sensor + openGate (no dynamic aspect): landscape buffer, +π/2, portrait playback ✓
//    - ratio9x16 (portrait reshape): portrait buffer, identity, portrait playback ✓
//    - ratio16x9 (landscape intent): landscape buffer, identity, landscape playback ✓
//

import AVFoundation
import CoreGraphics
import Foundation

/// Per-buffer-shape rotation policy. New device class behaviours that
/// produce unexpected buffer shapes still work as long as the shape is
/// classified correctly — no per-device overrides needed.
enum OrientationPolicy {

    /// Classification of the camera buffer's pixel shape. Driven by
    /// width-vs-height comparison.
    enum BufferShape: String, Sendable, Equatable {
        case portrait     // height > width (e.g., 2160×3840)
        case landscape    // width > height (e.g., 4032×3024)
        case square       // width == height (e.g., 3024×3024)

        /// Classify from explicit dims. Treats 0×0 (the iOS 26 cold-start
        /// race) as `.unknown`-equivalent — caller decides the fallback.
        static func from(width: Int, height: Int) -> BufferShape? {
            guard width > 0, height > 0 else { return nil }
            if width == height { return .square }
            return width > height ? .landscape : .portrait
        }

        /// Map an `AVCaptureDevice.AspectRatio` raw string to the buffer
        /// shape iOS produces when that aspect is applied. Synchronous and
        /// race-free: we know what we asked for, so we know what shape to
        /// expect — no waiting for `dynamicDimensions` to publish.
        ///
        /// QA REVIEWER FOCUS: this mapping is the basis for race-free
        /// preview rotation on cold start. If iOS ever changes how it
        /// reshapes for a given aspect (Apple has done this between point
        /// releases), this is where to update.
        static func from(dynamicAspectRaw: String?) -> BufferShape? {
            guard let raw = dynamicAspectRaw else { return nil }
            switch raw {
            case "AVCaptureAspectRatio9x16",
                 "AVCaptureAspectRatio3x4":
                return .portrait
            case "AVCaptureAspectRatio1x1":
                return .square
            case "AVCaptureAspectRatio4x3",
                 "AVCaptureAspectRatio16x9":
                return .landscape
            default:
                return nil
            }
        }
    }

    /// True for aspects whose intended PLAYBACK is portrait (taller than
    /// wide). 9:16, 4:3, 1:1, and openGate are all portrait-intent — the
    /// user holds the phone in portrait and expects portrait video out
    /// (1:1 is "portrait-compatible" in the sense that it doesn't need
    /// rotation either way). 16:9 is the only landscape-intent aspect.
    static func wantsPortraitPlayback(for aspect: RecordingAspect) -> Bool {
        switch aspect {
        case .ratio9x16, .ratio4x3, .ratio1x1, .openGate:
            return true
        case .ratio16x9:
            return false
        }
    }

    /// Writer's `videoInput.transform` for a (aspect, bufferShape) pair.
    ///
    /// Logic:
    ///   - 16:9 landscape-intent + landscape buffer → identity (already correct)
    ///   - 16:9 landscape-intent + portrait buffer  → -π/2 (turn portrait sideways into landscape — edge case)
    ///   - portrait-intent + landscape buffer       → +π/2 (rotate landscape to portrait)
    ///   - portrait-intent + portrait/square buffer → identity (already correct)
    ///
    /// QA REVIEWER FOCUS: the +π/2 sign was empirically derived in dogfood
    /// pass 11 from user reports of -π/2 producing upside-down playback.
    /// The combination "landscape buffer + +π/2 transform" produces upright
    /// portrait playback on iPhone 17 + iOS 26.x front camera (selfie-mounted).
    /// If a future device requires a different sign, override here.
    static func writerTransform(
        for aspect: RecordingAspect,
        bufferShape: BufferShape
    ) -> CGAffineTransform {
        if !wantsPortraitPlayback(for: aspect) {
            // 16:9 landscape intent
            switch bufferShape {
            case .landscape, .square:
                return .identity
            case .portrait:
                return CGAffineTransform(rotationAngle: -.pi / 2)
            }
        }
        // Portrait intent (everything except 16:9)
        switch bufferShape {
        case .landscape:
            return CGAffineTransform(rotationAngle: .pi / 2)
        case .portrait, .square:
            return .identity
        }
    }

    /// Preview-layer connection's `videoRotationAngle` for a (aspect,
    /// bufferShape) pair. AVCaptureConnection accepts 0/90/180/270;
    /// negative values aren't supported, so 270 is used for "rotate the
    /// other way."
    static func previewRotationAngle(
        for aspect: RecordingAspect,
        bufferShape: BufferShape
    ) -> CGFloat {
        if !wantsPortraitPlayback(for: aspect) {
            // 16:9 landscape intent
            switch bufferShape {
            case .landscape, .square:
                return 0
            case .portrait:
                return 270
            }
        }
        // Portrait intent
        switch bufferShape {
        case .landscape:
            return 90
        case .portrait, .square:
            return 0
        }
    }

    /// Resolve the user's current aspect from `Prefs`. Centralized so
    /// callers don't repeat the raw-string parsing.
    static var current: RecordingAspect {
        return RecordingAspect(rawValue: Prefs.recordingAspect) ?? .default
    }
}

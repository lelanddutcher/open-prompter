//
//  OrientationPolicy.swift
//  OpenPrompter
//
//  Sensor-orientation-aware rotation policy for the iPhone 17 selfie camera.
//
//  Hard-won lessons across passes 11-13d:
//
//  1. iPhone 17 selfie cam pixels are ALWAYS in sensor-natural orientation
//     (head pointing left, when phone is held in portrait), regardless of the
//     dynamic-aspect choice. Square-dim buffers (1:1, openGate 3840×3840) and
//     landscape-dim buffers (4:3 4032×3024) BOTH need the same rotation
//     correction to display upright. The buffer's W vs H proportion is NOT
//     a reliable signal for "should we rotate."
//
//  2. The WRITER's `videoInput.transform` and the PREVIEW's
//     `connection.videoRotationAngle` produce DIFFERENT visual results for
//     the same numeric angle, because the preview connection auto-mirrors
//     for selfie cam (`automaticallyAdjustsVideoMirroring=true` by default)
//     while the data output connection is explicitly un-mirrored. The mirror
//     inverts rotation handedness:
//       - WRITER (un-mirrored) +π/2 = visually upright portrait
//       - PREVIEW (mirrored) +π/2 = visually rotated 90° to the LEFT (i.e.,
//         the SAME numeric rotation but in the opposite visual direction).
//     To get a visually upright preview we use 270° (= -90° = the opposite
//     handedness).
//
//  3. iOS 26.3.1 doesn't expose ratio1x1 in the front camera's
//     `supportedDynamicAspectRatios`. The format selector falls back to
//     ratio4x3, producing a 4032×3024 LANDSCAPE buffer for openGate's
//     ratio1x1 preference (or a 3840×3840 square if a smaller format
//     declared ratio1x1 — confirmed working post-pass-13a). Either way the
//     pixels need the same rotation.
//
//  Empirical evidence (user reports on iPhone 17 Pro Max + iOS 26.3.1):
//    - 4:3 landscape buffer + writer +π/2 = upright playback ✓
//    - 1:1 / openGate square buffer + writer identity = ROTATED 90° LEFT ✗
//      → Square buffer pixels are in the SAME sensor orientation as landscape
//        buffer pixels; identity is wrong; +π/2 is right.
//    - 4:3 PIP at 90° preview = ROTATED 90° LEFT ✗
//      → Preview is auto-mirrored; 90° produces the opposite visual rotation
//        from the writer's +π/2; need 270° instead.
//    - 1:1 / openGate PIP at 0° preview = solid / fantastic ✓
//      → For square buffers, layer auto-handles the orientation (or the
//        rotation is visually invisible because square stays square). Keep 0°.
//

import AVFoundation
import CoreGraphics
import Foundation

/// Sensor-orientation-aware rotation policy.
enum OrientationPolicy {

    /// Classification of the camera buffer's pixel shape. Driven by
    /// width-vs-height comparison. Used by callers that still want to
    /// distinguish landscape from square (e.g., for self-test diagnostics
    /// and for the preview rotation, which needs different angles for
    /// landscape vs square because of the layer's mirror-handling).
    enum BufferShape: String, Sendable, Equatable {
        case portrait     // height > width (e.g., 2160×3840)
        case landscape    // width > height (e.g., 4032×3024)
        case square       // width == height (e.g., 3024×3024)

        /// Classify from explicit dims. Returns nil for 0×0 (cold-start
        /// race) so the caller can apply a defensive default.
        static func from(width: Int, height: Int) -> BufferShape? {
            guard width > 0, height > 0 else { return nil }
            if width == height { return .square }
            return width > height ? .landscape : .portrait
        }

        /// Map an `AVCaptureDevice.AspectRatio` raw string to the buffer
        /// shape iOS produces when that aspect is applied. Best-effort
        /// only — used for cold-start fallback when actual dims aren't
        /// available yet. iOS 26.3.1's actual reshape behaviour may differ
        /// from these labels, in which case the KVO on `dynamicDimensions`
        /// corrects within ~100ms.
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

    /// True for aspects whose intended PLAYBACK is portrait. Everything
    /// except 16:9 is portrait-intent on this app.
    static func wantsPortraitPlayback(for aspect: RecordingAspect) -> Bool {
        switch aspect {
        case .ratio9x16, .ratio4x3, .ratio1x1, .openGate:
            return true
        case .ratio16x9:
            return false
        }
    }

    /// Writer's `videoInput.transform`.
    ///
    /// The iPhone 17 selfie cam delivers pixels in TWO possible orientations
    /// depending on the buffer's dim shape:
    ///   - LANDSCAPE-DIM buffers (e.g., 4032×3024 for ratio4x3): pixels are
    ///     in sensor-natural orientation (rotated 90° from device-upright).
    ///     Need +π/2 to land upright portrait playback.
    ///   - SQUARE-DIM buffers (3024×3024 for ratio1x1, 3840×3840 for openGate):
    ///     pixels are ALSO sensor-natural — iOS doesn't rotate them because
    ///     square dims don't have a "portrait vs landscape" distinction to
    ///     trigger reshape. Same +π/2 rotation needed.
    ///   - PORTRAIT-DIM buffers (e.g., 2160×3840 for ratio9x16 if iOS
    ///     reshapes): pixels are device-upright because iOS physically rotated
    ///     them to fit the portrait container. Identity transform suffices.
    ///
    /// User-confirmed empirical evidence (iPhone 17 Pro Max + iOS 26.3.1):
    ///   - 4:3 (landscape buffer) + π/2 → upright ✓
    ///   - 1:1 / openGate (square buffer) + identity → ROTATED 90° LEFT ✗
    ///     (the pass-13b bug — square was grouped with portrait, both identity)
    ///   - 9:16 if iOS produces portrait buffer + identity → expected upright
    ///     (untested — depends on iOS reshape behaviour for ratio9x16)
    ///
    /// QA REVIEWER FOCUS: SQUARE buffers belong with LANDSCAPE in the
    /// portrait-intent branch (both need +π/2), NOT with portrait. This is
    /// the post-pass-13b correction.
    static func writerTransform(
        for aspect: RecordingAspect,
        bufferShape: BufferShape
    ) -> CGAffineTransform {
        if !wantsPortraitPlayback(for: aspect) {
            // 16:9 landscape intent
            switch bufferShape {
            case .landscape:
                // After the pass-13e 9x16↔16x9 swap, user-picked 16:9 maps
                // to iOS .ratio9x16, which produces a landscape buffer with
                // head-at-bottom orientation (different from 4:3's head-at-
                // left). Identity playback was upside-down per user testing
                // 2026-05-04 — 180° rotation flips it to upright.
                return CGAffineTransform(rotationAngle: .pi)
            case .square:
                return .identity
            case .portrait:
                // Edge case: iOS reshapes ratio16x9 to portrait-dim buffer.
                // -π/2 rotates portrait container into landscape playback.
                return CGAffineTransform(rotationAngle: -.pi / 2)
            }
        }
        // Portrait intent
        switch bufferShape {
        case .landscape, .square:
            // Sensor-natural pixels in non-portrait container — rotate +π/2
            // to land upright portrait playback.
            return CGAffineTransform(rotationAngle: .pi / 2)
        case .portrait:
            // iOS reshape rotated pixels into portrait container; identity
            // ships device-upright playback as-encoded.
            return .identity
        }
    }

    /// Preview-layer connection's `videoRotationAngle`. Always 0°.
    ///
    /// User testing on iPhone 17 Pro Max + iOS 26.3.1 (pass-13e):
    ///   - 90° on landscape buffer → "rotated 90° to the left" (wrong)
    ///   - 270° on landscape buffer → "rotated 90° to the right" (also wrong)
    ///   - 0° on square buffer → upright (correct)
    /// Both 90° and 270° produce wrong rotation in opposite directions for
    /// landscape buffers, while 0° is confirmed correct for square. The
    /// AVCaptureVideoPreviewLayer evidently applies its own device-orientation-
    /// aware rotation when `videoRotationAngle == 0`, and any non-zero value
    /// stacks ON TOP of that auto-rotation, breaking it.
    ///
    /// QA REVIEWER FOCUS: do NOT re-introduce buffer-shape branching here.
    /// 0° lets AVCaptureVideoPreviewLayer's built-in orientation handling do
    /// the right thing. The bufferShape parameter is kept for API symmetry
    /// with `writerTransform` and for future test-only use, but is unused.
    static func previewRotationAngle(
        for aspect: RecordingAspect,
        bufferShape: BufferShape
    ) -> CGFloat {
        _ = aspect       // kept for API symmetry / future per-aspect overrides
        _ = bufferShape  // kept for API symmetry / future per-shape overrides
        return 0
    }

    /// Resolve the user's current aspect from `Prefs`. Centralized so
    /// callers don't repeat the raw-string parsing.
    static var current: RecordingAspect {
        return RecordingAspect(rawValue: Prefs.recordingAspect) ?? .default
    }
}

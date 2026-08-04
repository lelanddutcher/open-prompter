//
//  OrientationPolicy.swift
//  OpenPrompter
//
//  Sensor-orientation-aware rotation policy for the iPhone 17 selfie camera.
//
//  ===================================================================
//  3.1 — WHAT CHANGED, AND WHAT DELIBERATELY DID NOT
//  ===================================================================
//
//  The PORTRAIT table below is untouched. Every lesson from passes 11-13g
//  still holds and still ships verbatim; `writerTransform(for:bufferShape:)`
//  is the same function it was, and `basePreviewRotationAngle(device:)` is the
//  same per-device row it was.
//
//  What changed is the LANDSCAPE path, which had shipped as hand-pinned
//  guesses (`HOLD_LANDSCAPE_*_UNVERIFIED`) composed on top of that verified
//  base — and on real hardware they double-rotated the file. Those constants
//  are DELETED. In their place, the extra rotation is a runtime DELTA read
//  from Apple's purpose-built `AVCaptureDevice.RotationCoordinator` (iOS 17+,
//  which is our deployment floor, so no availability gate):
//
//      delta = coordinatorAngleNow − coordinatorAngleWhileInterfacePortrait
//
//  Because both terms are the same Apple property in the same units, the
//  subtraction cancels every device/camera/sensor-specific constant — the
//  exact class of quirk that took thirteen dogfood passes to pin. The OS
//  supplies both the magnitude and the SIGN, so there is nothing left to
//  guess and nothing left to re-pin per device (iPad included).
//
//  The safety property, stated precisely: the reference is re-latched
//  continuously while the app's interface orientation is portrait, so
//  `delta == 0` for every portrait take, `holdRotation(deltaDegrees: 0)` is
//  `.identity`, and `x ∘ identity == x`. Portrait output is therefore
//  byte-identical to the verified pipeline BY CONSTRUCTION, not by
//  coincidence — see `testZeroDeltaEqualsVerifiedBaseForEveryShape`.
//
//  It also means the degraded case is safe rather than wrong: no coordinator,
//  no preview layer, or no portrait reference yet ⇒ delta 0 ⇒ exactly today's
//  behaviour.
//
//  Do NOT re-introduce a hand-pinned landscape constant. If landscape is off
//  on a device, the bug is in the delta plumbing (`RotationCoordinatorBox`)
//  or in the portrait base row — not in a number to flip.
//
//  ===================================================================
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
import UIKit

/// Sensor-orientation-aware rotation policy.
enum OrientationPolicy {

    // MARK: - Physical hold (V3 §07 — landscape auto-orientation)

    /// How the phone is physically held for a take, read from the foreground
    /// scene's INTERFACE orientation (see `currentPhysicalHold()`).
    /// Under auto-orientation, portrait-vs-landscape is a property of the
    /// hold, NOT of the picker shape (V3 §07). Cases are named after the
    /// UIKit *interface* orientation values (not device values) so there is
    /// no cross-namespace confusion inside our code — see the historical
    /// `UIInterfaceOrientation.landscapeLeft == UIDeviceOrientation.landscapeRight`
    /// inversion.
    ///
    /// 3.1 SCOPE CHANGE: `PhysicalHold` is now a CLASSIFICATION ONLY — it
    /// labels the take for the self-test report and drives the
    /// expected-playback-orientation math. It no longer carries any rotation
    /// constant: the writer's extra rotation comes from
    /// `AVCaptureDevice.RotationCoordinator` as a degree delta (see
    /// `holdRotation(deltaDegrees:)`). Nothing here is guessed any more.
    enum PhysicalHold: String, Sendable, Equatable {
        /// Phone upright, home-indicator down. This is the hold for which the
        /// coordinator delta is latched to zero, which is the anti-regression
        /// hinge that keeps portrait output byte-identical to the
        /// pass-13g-verified pipeline.
        case portrait
        /// Rotated so the top of the phone points LEFT (interface orientation).
        case landscapeLeft
        /// Rotated so the top of the phone points RIGHT (interface orientation).
        case landscapeRight
        // portrait-upside-down is intentionally NOT a recording orientation —
        // Info.plist doesn't list it and `currentPhysicalHold()` maps it to
        // `.portrait`. (V3 §07 §7.)
    }

    // MARK: - Rotation deltas (3.1 — AVCaptureDevice.RotationCoordinator)
    //
    // The two `HOLD_LANDSCAPE_*_UNVERIFIED` constants that used to live here
    // are GONE. They were hand-pinned guesses composed on top of the verified
    // portrait base, and on device they double-rotated the file (the 3.1
    // "rotated an extra degree in the wrong direction, like it's multiplied"
    // report). Their replacement is a runtime DELTA supplied by
    // `AVCaptureDevice.RotationCoordinator` (iOS 17+, our deployment floor —
    // no availability gate needed) via `RotationCoordinatorBox`:
    //
    //     delta = coordinatorAngleNow − coordinatorAngleWhileInterfacePortrait
    //
    // Both terms come from the SAME Apple property in the SAME units
    // (`AVCaptureConnection.videoRotationAngle` degrees), so the subtraction
    // cancels every device-, camera-, and sensor-specific constant that took
    // passes 13a-13g to pin. What survives is exactly "how much extra rotation
    // does the physical hold need, relative to upright" — magnitude AND sign,
    // both from the OS.
    //
    // THE ANTI-REGRESSION HINGE: the reference is re-latched continuously
    // whenever the app's interface orientation is portrait, so `delta == 0`
    // for every portrait take. `holdRotation(deltaDegrees: 0) == .identity`
    // and `x ∘ identity == x`, therefore portrait writer output is
    // byte-identical to the pass-13g-verified pipeline. Enforced mechanically
    // by `testZeroDeltaEqualsVerifiedBaseForEveryShape`.
    //
    // Degraded-but-safe fallback: with no coordinator (camera off, unit tests)
    // or no portrait reference yet (app launched in landscape and never went
    // upright), the delta is 0 — i.e. today's portrait behaviour. Never a
    // wrong guess, never a double rotation.

    /// Snap an arbitrary degree value to the nearest quarter turn and fold it
    /// into `(-180, 180]`. AVFoundation only ever vends 0/90/180/270, but the
    /// subtraction of two such values needs folding (e.g. `0 − 270 = −270`
    /// must read as `+90`). PURE — the unit under test.
    static func normalizedDeltaDegrees(_ degrees: CGFloat) -> CGFloat {
        guard degrees.isFinite else { return 0 }
        var d = (degrees / 90).rounded() * 90
        d = d.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d == 0 ? 0 : d          // normalise -0 to +0
    }

    /// Snap an arbitrary degree value into the `{0, 90, 180, 270}` set that
    /// `AVCaptureConnection.videoRotationAngle` accepts. PURE.
    static func normalizedConnectionAngle(_ degrees: CGFloat) -> CGFloat {
        guard degrees.isFinite else { return 0 }
        var d = (degrees / 90).rounded() * 90
        d = d.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d == 0 ? 0 : d
    }

    /// EXTRA rotation composed ON TOP OF the verified portrait base transform,
    /// expressed as the coordinator's degree delta from the portrait
    /// reference. `0` ⇒ `.identity` — the anti-regression hinge.
    ///
    /// Degrees→radians uses a POSITIVE sign because AVFoundation's
    /// `videoRotationAngle` and QuickTime's `preferredTransform` agree on
    /// handedness: a portrait iPhone video is `videoRotationAngle = 90` AND
    /// `preferredTransform = [0, 1, −1, 0] = CGAffineTransform(rotationAngle: +π/2)`.
    /// That equivalence is the anchor — NOT a fresh guess about handedness.
    static func holdRotation(deltaDegrees: CGFloat) -> CGAffineTransform {
        let d = normalizedDeltaDegrees(deltaDegrees)
        guard d != 0 else { return .identity }               // <-- guarantee
        return CGAffineTransform(rotationAngle: d * .pi / 180)
    }

    /// Horizontal (left↔right) flip in DISPLAY space — the selfie-mirror
    /// (3.1 item 3). Composed LAST so it mirrors the already-upright frame
    /// about its vertical axis regardless of the rotation that preceded it.
    /// Purely a `preferredTransform` flag: zero pixel cost, honored by
    /// Photos / QuickTime / AVFoundation.
    static let horizontalFlip = CGAffineTransform(scaleX: -1, y: 1)

    /// The physical hold for orientation decisions, read from the foreground
    /// scene's INTERFACE orientation. Main-actor only — read synchronously at
    /// REC tap (never per-frame, never device-notification-driven mid-take;
    /// see `RecordingSession.tapREC` and V3 §07 §4).
    ///
    /// Interface orientation (not `UIDevice.current.orientation`, not CMMotion)
    /// is the correct source: it is what the app's UI is *actually displaying
    /// as*, which is the same signal `AVCaptureVideoPreviewLayer`'s
    /// auto-rotation keys off — so the recorded file and the live preview
    /// cannot disagree. The app already resolves the active window scene this
    /// way for the review prompt (`ReviewPromptController.activeWindowScene()`).
    @MainActor
    static func currentPhysicalHold() -> PhysicalHold {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        switch scene?.interfaceOrientation {
        case .landscapeLeft:  return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default:              return .portrait   // portrait + upside-down + unknown
        }
    }

    /// !!! UNVERIFIED, DEVICE-BLOCKED PLACEHOLDER (V3 Design 06 / GitHub #2) !!!
    ///
    /// Preview `videoRotationAngle` (DEGREES) for the `.wideFrontSensor`
    /// generation class (iPhone 16 / 15 / 14 / 13 / SE — any 4:3-front-sensor
    /// device). GitHub #2 reports the iPhone 13 Pro live preview as "rotated
    /// 90° and locked"; the recorded FILE plays back correct, so this is a
    /// PREVIEW-only defect and the writer transforms are untouched.
    ///
    /// We do NOT own an iPhone 13 Pro, so we CANNOT confirm the correct angle
    /// here. This constant is the single data row the #2 reporter must confirm
    /// (see V3 Design 06 §5 — ship the DEBUG angle-cycler, ask the reporter
    /// which of 0/90/180/270 lands upright, then set this and drop `_UNVERIFIED`).
    ///
    /// Working hypothesis = `270`: the selfie preview connection auto-mirrors
    /// (`automaticallyAdjustsVideoMirroring == true`), which inverts rotation
    /// handedness, so the mirror-inverted 90° (= 270°) is the most likely
    /// upright value given a "rotated 90°" report. This is a HYPOTHESIS to
    /// test with the reporter, NOT a known-good value.
    ///
    /// Do NOT present this number as verified anywhere in shipping copy.
    static let PREVIEW_ANGLE_WIDE_FRONT_UNVERIFIED: CGFloat = 270

    /// Coarse front-camera generation class. The ONLY thing the preview
    /// rotation policy branches on beyond `(aspect, bufferShape)`. Derived
    /// from `utsname.machine`, but classified by the property that actually
    /// matters for orientation — the native FRONT-SENSOR aspect — not by
    /// marketing name.
    enum DeviceGenerationHint: String, Sendable, Equatable {
        /// Front sensor is natively 1:1 (square). iPhone 17 family
        /// (`iPhone18,x` and up). This is the VERIFIED-correct baseline
        /// (iPhone 17 Pro Max + iOS 26.3.1, pass-13e); its preview rows must
        /// NOT change.
        case squareFrontSensor

        /// Front sensor is natively 4:3. iPhone 16 / 15 / 14 / 13 / SE and
        /// most pre-17 iPhones (`iPhone17,x` and below). iPhone 13 Pro
        /// (GitHub #2) lands here. Preview angle for this class is UNVERIFIED —
        /// see `PREVIEW_ANGLE_WIDE_FRONT_UNVERIFIED` and V3 Design 06 §5.
        case wideFrontSensor

        /// Unknown / future / iPad / simulator model we haven't classified.
        /// Falls back to the `.squareFrontSensor` preview rows (current shipped
        /// behavior) so an unrecognized device is never worse off than today.
        case unknown

        /// Classify from the raw `utsname.machine` identifier (e.g.
        /// `"iPhone18,2"`, `"iPhone14,2"`, `"iPhone15,4"`, `"x86_64"`,
        /// `"arm64"`).
        ///
        /// PURE. No AVFoundation, no `UIDevice`, no globals — this is the unit
        /// under test in the multi-sim harness. The `>= 18` cutoff is the
        /// single load-bearing constant (iPhone 17 family = `iPhone18,x`
        /// reports a 1:1 front sensor, confirmed on the founder's device);
        /// it ASSUMES future families keep a square front sensor, which is a
        /// documented, revisitable assumption (V3 Design 06 §2.1). A future
        /// non-square-front device at gen ≥ 18 would be mis-classified as
        /// `.squareFrontSensor` and simply get today's shipped behavior — the
        /// safe default — with a self-test report flagging it for a row add.
        static func from(modelIdentifier raw: String) -> DeviceGenerationHint {
            if let gen = iPhoneGeneration(from: raw) {
                return gen >= 18 ? .squareFrontSensor : .wideFrontSensor
            }
            // Non-iPhone (iPad "iPadN,M", sim "x86_64"/"arm64", Mac, etc.):
            // we have no verified front-sensor data → unknown → safe default.
            return .unknown
        }

        /// Parse the leading generation integer out of `"iPhoneNN,M"`.
        /// Returns nil for any non-`"iPhone…,…"` string (iPad, sim host,
        /// marketing-only `"iPhone"`, empty).
        private static func iPhoneGeneration(from raw: String) -> Int? {
            guard raw.hasPrefix("iPhone") else { return nil }
            let rest = raw.dropFirst("iPhone".count)          // "18,2"
            guard let comma = rest.firstIndex(of: ",") else { return nil }
            return Int(rest[..<comma])                        // 18
        }
    }

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

    /// Under auto-orientation (V3 §07), portrait-vs-landscape playback intent
    /// is the HOLD, not the shape. This public overload is the source of
    /// truth for the self-test's expected-aspect math. Shape no longer decides
    /// this — held upright = portrait playback, held sideways = landscape,
    /// regardless of which shape is picked.
    static func wantsPortraitPlayback(for hold: PhysicalHold) -> Bool {
        hold == .portrait
    }

    /// INTERNAL, UNCHANGED (V3 §07 §2.3). The shape-based portrait-intent
    /// predicate used ONLY inside the verified 2-arg `writerTransform` to
    /// select its branch. Its branch selection is preserved VERBATIM: `.wide`
    /// (the merged 16:9 shape, raw `"ratio16x9"`) is the sole landscape-intent
    /// (`false`) case — exactly as the old `.ratio16x9` was — so the 2-arg
    /// function still hits the `!wantsPortraitPlayback` branch for `.wide`
    /// (portrait buffer → +π/2, the verified 16:9-user-pick value). Reads
    /// `.canonicalShape` so the `.legacyVertical9x16` alias resolves to `.wide`
    /// consistently. This is NOT a public predicate — the public one above is
    /// hold-based. Do NOT flip `.wide` into the `true` branch: that returns
    /// identity for a portrait buffer and would silently change today's 16:9
    /// output from +π/2 to identity (caught by the anti-regression test).
    fileprivate static func wantsPortraitPlayback(forShape aspect: RecordingAspect) -> Bool {
        switch aspect.canonicalShape {
        case .classic, .square, .openGate:
            return true
        case .wide:
            return false
        case .legacyVertical9x16:
            // Unreachable after canonicalShape (collapses to .wide). Matches
            // .wide's landscape-intent classification for exhaustiveness.
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
        if !wantsPortraitPlayback(forShape: aspect) {
            // 16:9 landscape intent. After the pass-13e 9x16↔16x9 swap,
            // user-picked 16:9 maps to iOS .ratio9x16. Per the pass-13f
            // self-test JSON for ratio16x9 user-pick on iPhone 17 Pro Max
            // + iOS 26.3.1: iOS produces a 2160×3840 PORTRAIT buffer
            // (not landscape). Buffer pixels are sensor-natural with head-
            // at-right orientation; +π/2 rotates head-right to head-top
            // (upright) and swaps dims to 3840×2160 landscape playback.
            switch bufferShape {
            case .portrait:
                // The actual case hit by 16:9 user-pick. +π/2 was -π/2 in
                // pass-13d/e (which gave upside-down per user 2026-05-04).
                return CGAffineTransform(rotationAngle: .pi / 2)
            case .landscape, .square:
                // Defensive — not hit on iPhone 17 + iOS 26.3.1 for the
                // current swap mapping, but kept for hardware classes that
                // may produce non-portrait buffers for ratio9x16. Identity
                // is the conservative default; revisit per-device if a user
                // hits this path with rotated content.
                return .identity
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

    /// Full writer `videoInput.transform` (3.1 — coordinator-driven).
    /// ADDITIVE over the verified 2-arg function — it is a COMPOSITION:
    ///
    ///     final = base(shape, bufferShape) ∘ holdRotation(delta) ∘ [flip]
    ///
    /// where `base` IS the untouched 2-arg `writerTransform(for:bufferShape:)`
    /// above (defined as "the transform that lands upright playback when the
    /// phone is held in PORTRAIT" — exactly what pass-13g verified), `delta`
    /// is the `AVCaptureDevice.RotationCoordinator` capture-angle delta from
    /// the portrait reference (0 in portrait, ±90/180 sideways), and `flip`
    /// is the optional selfie-mirror.
    ///
    /// Because `holdRotation(deltaDegrees: 0) == .identity` and
    /// `x ∘ identity == x`, the zero-delta result equals today's verified
    /// value BYTE-FOR-BYTE for every (shape × bufferShape) cell — enforced
    /// mechanically by `testZeroDeltaEqualsVerifiedBaseForEveryShape`.
    ///
    /// Composition order: `base.concatenating(hold)` applies `base` first,
    /// then `hold` — `base` already lands upright-portrait, so `hold` rotates
    /// that upright frame by the physical tilt. Rotations commute, so the
    /// order is immaterial for the rotation pair; it is NOT immaterial once
    /// `flip` joins, which is why the flip is applied LAST (mirroring the
    /// final display frame about its vertical axis, which is what a user
    /// means by "selfie mirror").
    ///
    /// Reads `.canonicalShape` internally (via the 2-arg call and the shape
    /// predicate) so a stray `.legacyVertical9x16` resolves to `.wide`.
    ///
    /// - Parameter captureDeltaDegrees: normally
    ///   `OrientationPolicy.currentCaptureDeltaDegrees` latched at REC tap.
    /// - Parameter mirrored: `Prefs.recordingMirrorVideo`.
    static func writerTransform(
        for aspect: RecordingAspect,
        captureDeltaDegrees: CGFloat,
        bufferShape: BufferShape,
        mirrored: Bool = false
    ) -> CGAffineTransform {
        let base = writerTransform(for: aspect.canonicalShape, bufferShape: bufferShape) // UNCHANGED 2-arg
        let rotated = base.concatenating(holdRotation(deltaDegrees: captureDeltaDegrees))
        guard mirrored else { return rotated }
        return rotated.concatenating(horizontalFlip)
    }

    /// Preview-layer connection's `videoRotationAngle` (DEGREES), keyed by
    /// device generation. Returns 0/90/180/270 to match
    /// `connection.videoRotationAngle`'s units — UNLIKE `writerTransform`,
    /// which returns radians. That unit split already exists in the codebase
    /// (`applyOrientationDependentRotation` assigns this value straight onto
    /// `connection.videoRotationAngle`); we keep it.
    ///
    /// - `.squareFrontSensor` / `.unknown`: VERIFIED baseline (iPhone 17 Pro
    ///   Max + iOS 26.3.1, pass-13e). `AVCaptureVideoPreviewLayer`'s own
    ///   device-orientation-aware rotation is correct here; any non-zero angle
    ///   stacks on top and breaks it. Confirmed 0/90/270 by user testing:
    ///     - 90° on landscape buffer → "rotated 90° to the left" (wrong)
    ///     - 270° on landscape buffer → "rotated 90° to the right" (also wrong)
    ///     - 0° → upright (correct)
    ///   `.unknown` deliberately shares this row so unrecognized devices get
    ///   today's shipped behavior, never worse. DO NOT change this row without
    ///   re-verifying on a 1:1-front-sensor device.
    /// - `.wideFrontSensor`: GitHub #2 (iPhone 13 Pro, 4:3 front sensor) shows
    ///   the preview rotated 90° and locked — the layer's built-in auto-rotation
    ///   does NOT land upright for this sensor class. The angle is UNVERIFIED /
    ///   device-blocked; see `PREVIEW_ANGLE_WIDE_FRONT_UNVERIFIED` and the
    ///   confirmation loop in V3 Design 06 §5.
    ///
    /// QA REVIEWER FOCUS: the DEVICE axis was added ONLY to this preview
    /// function. `writerTransform` is untouched (recording is verified correct
    /// on both sensor classes per #2). Do NOT invent a verified non-zero value
    /// for `.wideFrontSensor`; it ships as the named placeholder.
    static func previewRotationAngle(
        for aspect: RecordingAspect,
        bufferShape: BufferShape,
        device: DeviceGenerationHint,
        previewDeltaDegrees: CGFloat = 0
    ) -> CGFloat {
        _ = aspect       // kept for API symmetry / future per-aspect overrides
        _ = bufferShape  // kept for API symmetry / future per-shape overrides

        // 3.1: the PORTRAIT-REFERENCE angle (unchanged rows below) plus the
        // coordinator's live delta from portrait. Delta is 0 whenever the
        // interface is portrait — or whenever no coordinator/reference exists
        // — so every previously-verified portrait value is returned verbatim.
        // Sideways, the delta is what fixes the "PiP preview doesn't rotate"
        // half of the 3.1 rotation bug.
        let base = basePreviewRotationAngle(device: device)
        return normalizedConnectionAngle(base + normalizedDeltaDegrees(previewDeltaDegrees))
    }

    /// The PORTRAIT-hold preview angle per device class. This is the pinned
    /// table — pass-13e verified `0` for `.squareFrontSensor`; `.wideFrontSensor`
    /// is still the GitHub #2 placeholder. Split out of `previewRotationAngle`
    /// so the delta composition can't be confused with the table itself.
    static func basePreviewRotationAngle(device: DeviceGenerationHint) -> CGFloat {
        switch device {
        case .squareFrontSensor, .unknown:
            return 0
        case .wideFrontSensor:
            #if DEBUG
            // DEBUG angle-cycler override (Settings → Labs → "wide-front
            // preview angle"). When the founder / #2 reporter cycles the angle
            // to find the upright value, this returns their chosen degrees
            // instead of the placeholder. `nil` = no override = ship the
            // hypothesis. Release builds ALWAYS use the placeholder (the
            // override read is compiled out below).
            if let override = debugWideFrontPreviewAngleOverride {
                return override
            }
            #endif
            return PREVIEW_ANGLE_WIDE_FRONT_UNVERIFIED
        }
    }

    /// Back-compat 2-arg overload — resolves the device hint from the live
    /// model identifier and forwards to the primary version with a ZERO delta
    /// (i.e. the portrait-reference answer). Kept so callers / tests that
    /// don't care about the device or rotation axes stay terse; the primary
    /// call site (`CameraPreview.applyOrientationDependentRotation`) passes an
    /// explicit hint AND the live delta.
    static func previewRotationAngle(
        for aspect: RecordingAspect,
        bufferShape: BufferShape
    ) -> CGFloat {
        return previewRotationAngle(
            for: aspect,
            bufferShape: bufferShape,
            device: DeviceGenerationHint.from(modelIdentifier: currentDeviceModelIdentifier)
        )
    }

    // MARK: - Live rotation source (registered by CameraStore)

    /// The live `AVCaptureDevice.RotationCoordinator` wrapper, registered by
    /// `CameraStore` when the capture session comes up and cleared when it
    /// goes down. `weak` so the store stays the owner.
    ///
    /// This is deliberately the ONE global read point: keeping the decision in
    /// `OrientationPolicy` (rather than letting each consumer talk to the
    /// coordinator itself) is what stops rotation logic from scattering again.
    /// Main-actor only — the writer path must LATCH the delta on the main
    /// actor at REC tap and carry it into `WriterState`, never read it from
    /// the recording queue.
    @MainActor static weak var rotationSource: RotationCoordinatorBox?

    /// Live capture-angle delta from the portrait reference, in degrees.
    /// `0` when no coordinator is bound or no portrait reference has been
    /// latched yet — the safe, today's-behaviour default.
    @MainActor static var currentCaptureDeltaDegrees: CGFloat {
        rotationSource?.captureDeltaDegrees ?? 0
    }

    /// Live preview-angle delta from the portrait reference, in degrees.
    /// `0` when no coordinator is bound, no preview layer is in the hierarchy
    /// (the coordinator returns 0 degrees for preview in that case — see the
    /// `AVCaptureDeviceRotationCoordinator` header), or no portrait reference
    /// has been latched yet.
    @MainActor static var currentPreviewDeltaDegrees: CGFloat {
        rotationSource?.previewDeltaDegrees ?? 0
    }

    /// Resolve the user's current aspect SHAPE from `Prefs`. Centralized so
    /// callers don't repeat the raw-string parsing. Returns `.canonicalShape`
    /// so a stray persisted `.legacyVertical9x16` (V3 §07 alias, e.g. from
    /// iCloud KVS mirror lag before the one-shot migration runs) resolves to
    /// `.wide` before it ever reaches the policy table.
    static var current: RecordingAspect {
        return (RecordingAspect(rawValue: Prefs.recordingAspect) ?? .default).canonicalShape
    }

    /// The device's hardware identifier (e.g. `"iPhone18,2"` for iPhone 17
    /// Pro Max, `"iPhone14,2"` for iPhone 13 Pro) via `utsname`. SINGLE source
    /// of truth for the uname read — `RecordingSelfTest` consumes this too, so
    /// there is exactly one parser. `UIDevice.current.model` only returns the
    /// marketing class (`"iPhone"`); we want the specific hardware revision so
    /// the preview policy can branch by front-sensor generation.
    ///
    /// Synchronous and race-free (unlike `dynamicDimensions`), which is why
    /// the rotation decision keys off THIS and not a probed buffer — matching
    /// CLAUDE.md lesson 6 ("read intent synchronously, never probe buffers for
    /// rotation decisions").
    static var currentDeviceModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.compactMap { element -> String? in
            guard let value = element.value as? Int8, value != 0 else { return nil }
            return String(UnicodeScalar(UInt8(bitPattern: value)))
        }.joined()
    }

    #if DEBUG
    /// UserDefaults key backing the DEBUG wide-front preview angle-cycler.
    /// Namespaced so it never collides with a `PrefKey`. Not a `PrefKey` case
    /// on purpose — it's a DEBUG diagnostic surface, not a user preference.
    private static let debugWideFrontAngleKey = "debug.orientation.wideFrontPreviewAngle"

    /// Current DEBUG override for the `.wideFrontSensor` preview angle, or
    /// `nil` when no override is active (ship the hypothesis). Stored as a
    /// sentinel: absent / negative = no override; 0/90/180/270 = override.
    static var debugWideFrontPreviewAngleOverride: CGFloat? {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: debugWideFrontAngleKey) != nil else { return nil }
            let stored = defaults.double(forKey: debugWideFrontAngleKey)
            return stored < 0 ? nil : CGFloat(stored)
        }
        set {
            let defaults = UserDefaults.standard
            if let newValue {
                defaults.set(Double(newValue), forKey: debugWideFrontAngleKey)
            } else {
                defaults.removeObject(forKey: debugWideFrontAngleKey)
            }
        }
    }

    /// Advance the DEBUG wide-front angle-cycler one step:
    /// `nil (hypothesis) → 0 → 90 → 180 → 270 → nil`. Returns the new value so
    /// the caller can surface it. This is the closed-loop tool for the #2
    /// reporter to find the upright angle live (V3 Design 06 §5).
    @discardableResult
    static func cycleDebugWideFrontPreviewAngle() -> CGFloat? {
        let next: CGFloat?
        switch debugWideFrontPreviewAngleOverride {
        case .none:       next = 0
        case .some(0):    next = 90
        case .some(90):   next = 180
        case .some(180):  next = 270
        default:          next = nil   // 270 or any other → back to hypothesis
        }
        debugWideFrontPreviewAngleOverride = next
        return next
    }
    #endif
}

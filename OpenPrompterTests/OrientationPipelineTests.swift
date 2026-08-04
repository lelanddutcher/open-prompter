//
//  OrientationPipelineTests.swift
//  OpenPrompterTests
//
//  Pinned coverage of the rotation/orientation pipeline. The dogfood-pass-13
//  rewrite: rotation policy now derives from BOTH the user's picker aspect
//  AND the actual buffer shape (portrait/landscape/square). Self-test on
//  iPhone 17 Pro Max + iOS 26.3.1 confirmed the front camera does NOT expose
//  ratio1x1 in supportedDynamicAspectRatios, so openGate falls back to
//  ratio4x3 producing a 4032×3024 LANDSCAPE buffer. The previous aspect-
//  only policy returned identity for openGate and shipped landscape playback;
//  the new buffer-shape-aware policy detects "landscape buffer + portrait-
//  intent aspect" and rotates +π/2.
//
//  These tests pin the corrected behaviour:
//
//    1. `OrientationPolicy.writerTransform(for:bufferShape:)` — for
//       portrait-intent aspects (9:16/4:3/1:1/openGate), landscape buffers
//       get +π/2; portrait/square buffers get identity. For 16:9 landscape-
//       intent: identity for landscape buffers, -π/2 for the edge case
//       portrait buffer.
//    2. `OrientationPolicy.previewRotationAngle(for:bufferShape:)` — same
//       logic for the preview connection's `videoRotationAngle`.
//    3. `RecordingSelfTest.playbackDimensions(...)` — composes encoded dims
//       with `preferredTransform` to compute display orientation.
//    4. End-to-end integration: every (aspect, buffer) combo the user can
//       land in produces portrait-or-square playback (16:9 landscape-intent
//       is the deliberate exception).
//

import XCTest
import CoreGraphics
@testable import OpenPrompter

final class OrientationPipelineTests: XCTestCase {

    // MARK: - BufferShape classification

    func testBufferShapeFromDimsLandscape() {
        XCTAssertEqual(OrientationPolicy.BufferShape.from(width: 4032, height: 3024), .landscape)
    }

    func testBufferShapeFromDimsPortrait() {
        XCTAssertEqual(OrientationPolicy.BufferShape.from(width: 2160, height: 3840), .portrait)
    }

    func testBufferShapeFromDimsSquare() {
        XCTAssertEqual(OrientationPolicy.BufferShape.from(width: 3024, height: 3024), .square)
    }

    func testBufferShapeFromDimsZeroReturnsNil() {
        // The iOS 26 dynamicDimensions cold-start race returns 0×0 — caller
        // must fall through to a defensive default (we use .landscape).
        XCTAssertNil(OrientationPolicy.BufferShape.from(width: 0, height: 0))
        XCTAssertNil(OrientationPolicy.BufferShape.from(width: 4032, height: 0))
    }

    func testBufferShapeFromAspectRawMappings() {
        XCTAssertEqual(OrientationPolicy.BufferShape.from(dynamicAspectRaw: "AVCaptureAspectRatio9x16"), .portrait)
        XCTAssertEqual(OrientationPolicy.BufferShape.from(dynamicAspectRaw: "AVCaptureAspectRatio3x4"), .portrait)
        XCTAssertEqual(OrientationPolicy.BufferShape.from(dynamicAspectRaw: "AVCaptureAspectRatio1x1"), .square)
        XCTAssertEqual(OrientationPolicy.BufferShape.from(dynamicAspectRaw: "AVCaptureAspectRatio4x3"), .landscape)
        XCTAssertEqual(OrientationPolicy.BufferShape.from(dynamicAspectRaw: "AVCaptureAspectRatio16x9"), .landscape)
        XCTAssertNil(OrientationPolicy.BufferShape.from(dynamicAspectRaw: nil))
        XCTAssertNil(OrientationPolicy.BufferShape.from(dynamicAspectRaw: "AVCaptureAspectRatioBogus"))
    }

    // MARK: - wantsPortraitPlayback (V3 §07: hold-based intent)
    //
    // Under auto-orientation, portrait-vs-landscape playback is the HOLD,
    // not the shape. The public predicate takes a PhysicalHold.

    func testWantsPortraitPlaybackIsHoldBased() {
        XCTAssertTrue(OrientationPolicy.wantsPortraitPlayback(for: .portrait))
        XCTAssertFalse(OrientationPolicy.wantsPortraitPlayback(for: .landscapeLeft))
        XCTAssertFalse(OrientationPolicy.wantsPortraitPlayback(for: .landscapeRight))
    }

    // MARK: - writerTransform 2-arg base (shape × bufferShape) — V3 §07 shapes
    //
    // These pin the UNTOUCHED verified base transform. `.wide` (raw
    // "ratio16x9") is the merged 16:9 shape and stays the sole landscape-
    // intent case internally, so its portrait-buffer cell returns +π/2 — the
    // verified 16:9-user-pick value. `.classic` / `.square` / `.openGate` are
    // portrait-intent.

    func testWriterTransformPortraitIntentLandscapeBufferRotates() {
        // openGate falling back to ratio4x3 on iPhone 17 + iOS 26.3.1 → 4032×3024
        // landscape. Want portrait playback → +π/2 rotation.
        for aspect in [RecordingAspect.openGate, .classic, .square] {
            let t = OrientationPolicy.writerTransform(for: aspect, bufferShape: .landscape)
            XCTAssertEqual(t.a, 0, accuracy: 1e-6, "\(aspect): a")
            XCTAssertEqual(t.b, 1, accuracy: 1e-6, "\(aspect): b")
            XCTAssertEqual(t.c, -1, accuracy: 1e-6, "\(aspect): c")
            XCTAssertEqual(t.d, 0, accuracy: 1e-6, "\(aspect): d")
        }
    }

    func testWriterTransformPortraitIntentPortraitBufferIdentity() {
        // Portrait-intent shapes on a portrait buffer: iOS already rotated
        // pixels into the portrait container, so identity ships upright.
        for aspect in [RecordingAspect.classic, .openGate] {
            let t = OrientationPolicy.writerTransform(for: aspect, bufferShape: .portrait)
            XCTAssertEqual(t, .identity, "\(aspect) on portrait buffer")
        }
    }

    func testWriterTransformPortraitIntentSquareBufferRotates() {
        // SQUARE buffers (1:1, openGate 3840×3840) come out with sensor-
        // natural pixel orientation — iOS doesn't rotate them during reshape
        // because square dims have no portrait/landscape distinction. Need
        // +π/2 to land upright playback. This is the post-pass-13b fix
        // (was identity; user-confirmed wrong on iPhone 17 Pro Max iOS 26.3.1).
        for aspect in [RecordingAspect.square, .openGate] {
            let t = OrientationPolicy.writerTransform(for: aspect, bufferShape: .square)
            XCTAssertEqual(t.a, 0, accuracy: 1e-6, "\(aspect) on square: a")
            XCTAssertEqual(t.b, 1, accuracy: 1e-6, "\(aspect) on square: b")
            XCTAssertEqual(t.c, -1, accuracy: 1e-6, "\(aspect) on square: c")
            XCTAssertEqual(t.d, 0, accuracy: 1e-6, "\(aspect) on square: d")
        }
    }

    func testWriterTransformWideLandscapeBufferIdentity() {
        // .wide (merged 16:9) + landscape buffer is defensive-only on iPhone
        // 17 + iOS 26.3.1 — iOS produces portrait (not landscape) buffers for
        // the wide shape (via the swapped iOS .ratio9x16 mapping). Kept as
        // identity for hardware classes that may produce landscape.
        let t = OrientationPolicy.writerTransform(for: .wide, bufferShape: .landscape)
        XCTAssertEqual(t, .identity)
    }

    func testWriterTransformWidePortraitBufferIsPositivePiOverTwo() {
        // The actual case hit on iPhone 17 + iOS 26.3.1 for the .wide shape.
        // iOS produces a 2160×3840 portrait buffer with sensor-natural pixels
        // (head at right). +π/2 rotates head-at-right → head-at-top (upright)
        // and swaps playback dims to 3840×2160 landscape. This is the verified
        // 16:9-user-pick value the merge must preserve (V3 §07 §2.3).
        let t = OrientationPolicy.writerTransform(for: .wide, bufferShape: .portrait)
        XCTAssertEqual(t.a, 0, accuracy: 1e-6)
        XCTAssertEqual(t.b, 1, accuracy: 1e-6)
        XCTAssertEqual(t.c, -1, accuracy: 1e-6)
        XCTAssertEqual(t.d, 0, accuracy: 1e-6)
    }

    // MARK: - 3.1 MANDATORY anti-regression guard
    //
    // THE single load-bearing guarantee of the RotationCoordinator adoption:
    // a ZERO capture delta must reproduce the verified 2-arg transform for
    // every (shape × bufferShape) cell, EXACTLY — not approximately. A zero
    // delta is what every portrait take produces (the coordinator's portrait
    // reference is re-latched whenever the interface is upright) and what
    // every uncalibrated / camera-off / unit-test take produces. So this test
    // is the proof that portrait output cannot change.
    //
    // Asserted with `==` on the whole transform rather than component-wise
    // accuracy: `holdRotation(deltaDegrees: 0)` returns `.identity` by an
    // early return, and `x.concatenating(.identity)` is exact, so there is no
    // floating-point slack to allow for. If someone "simplifies" that early
    // return into `CGAffineTransform(rotationAngle: 0)` the result is still
    // mathematically identity but no longer bit-exact, and this test says so.

    func testZeroDeltaEqualsVerifiedBaseForEveryShape() {
        let shapes: [RecordingAspect] = [.wide, .classic, .square, .openGate, .legacyVertical9x16]
        let buffers: [OrientationPolicy.BufferShape] = [.portrait, .landscape, .square]
        for shape in shapes {
            for buffer in buffers {
                let verified = OrientationPolicy.writerTransform(       // 2-arg, untouched
                    for: shape.canonicalShape, bufferShape: buffer)
                let composed = OrientationPolicy.writerTransform(       // coordinator form
                    for: shape, captureDeltaDegrees: 0, bufferShape: buffer)
                XCTAssertEqual(composed, verified, "\(shape) × \(buffer) must be bit-identical at zero delta")
            }
        }
    }

    /// The un-mirrored default must ALSO be bit-identical — the selfie-mirror
    /// feature must not perturb the verified path when it is off (its `Prefs`
    /// default). Guards against an "always compose the flip, with scale 1"
    /// refactor that would introduce float noise into every recording.
    func testMirrorOffIsBitIdenticalToVerifiedBase() {
        for shape in [RecordingAspect.wide, .classic, .square, .openGate] {
            for buffer in [OrientationPolicy.BufferShape.portrait, .landscape, .square] {
                let verified = OrientationPolicy.writerTransform(for: shape, bufferShape: buffer)
                let composed = OrientationPolicy.writerTransform(
                    for: shape, captureDeltaDegrees: 0, bufferShape: buffer, mirrored: false)
                XCTAssertEqual(composed, verified, "\(shape) × \(buffer) with mirror off")
            }
        }
    }

    /// The merged `.wide` (raw "ratio16x9") on a portrait buffer must still be
    /// +π/2 — the verified 16:9-user-pick value. Guards §2.3's raw-value reuse
    /// against a "cleanup" that flips `.wide` into the portrait-intent branch.
    func testWideShapePortraitBufferIsVerifiedPlusPiOverTwo() {
        let t = OrientationPolicy.writerTransform(
            for: .wide, captureDeltaDegrees: 0, bufferShape: .portrait)
        XCTAssertEqual(t.a, 0, accuracy: 0.0001)
        XCTAssertEqual(t.b, 1, accuracy: 0.0001)   // +π/2 rotation: a=0,b=1,c=-1,d=0
        XCTAssertEqual(t.c, -1, accuracy: 0.0001)
        XCTAssertEqual(t.d, 0, accuracy: 0.0001)
    }

    /// The downgrade-safety alias must resolve to the same output as `.wide`.
    func testLegacyVerticalAliasResolvesToWide() {
        for buffer in [OrientationPolicy.BufferShape.portrait, .landscape, .square] {
            let aliased = OrientationPolicy.writerTransform(
                for: .legacyVertical9x16, captureDeltaDegrees: 0, bufferShape: buffer)
            let wide = OrientationPolicy.writerTransform(
                for: .wide, captureDeltaDegrees: 0, bufferShape: buffer)
            XCTAssertEqual(aliased, wide, "\(buffer)")
        }
    }

    // MARK: - 3.1 delta math (replaces the deleted _UNVERIFIED constants)

    /// Zero delta is identity — the composition hinge everything else rests on.
    func testHoldRotationZeroDeltaIsIdentity() {
        XCTAssertTrue(OrientationPolicy.holdRotation(deltaDegrees: 0).isIdentity)
        // Values that FOLD to zero must also land on identity, not on a
        // rotation-by-360 that is only approximately identity.
        XCTAssertTrue(OrientationPolicy.holdRotation(deltaDegrees: 360).isIdentity)
        XCTAssertTrue(OrientationPolicy.holdRotation(deltaDegrees: -360).isIdentity)
    }

    /// A ±90 delta produces the matching quarter-turn, with the SIGN carried
    /// straight through from the coordinator. The degrees→radians mapping is
    /// positive because AVFoundation's `videoRotationAngle` and QuickTime's
    /// `preferredTransform` agree on handedness: a portrait iPhone video is
    /// simultaneously `videoRotationAngle = 90` and `preferredTransform =
    /// [0, 1, -1, 0]`, which is `CGAffineTransform(rotationAngle: +π/2)`.
    func testHoldRotationQuarterTurnsCarryTheCoordinatorSign() {
        let plus = OrientationPolicy.holdRotation(deltaDegrees: 90)
        XCTAssertEqual(plus.a, 0, accuracy: 1e-9)
        XCTAssertEqual(plus.b, 1, accuracy: 1e-9)
        XCTAssertEqual(plus.c, -1, accuracy: 1e-9)
        XCTAssertEqual(plus.d, 0, accuracy: 1e-9)

        let minus = OrientationPolicy.holdRotation(deltaDegrees: -90)
        XCTAssertEqual(minus.a, 0, accuracy: 1e-9)
        XCTAssertEqual(minus.b, -1, accuracy: 1e-9)
        XCTAssertEqual(minus.c, 1, accuracy: 1e-9)
        XCTAssertEqual(minus.d, 0, accuracy: 1e-9)

        // The two sideways holds are opposite handedness — the property the
        // deleted `HOLD_LANDSCAPE_*_UNVERIFIED` pair used to assert by hand.
        XCTAssertEqual(plus.b, -minus.b, accuracy: 1e-9)
    }

    /// Delta folding: the coordinator vends absolute angles in `{0,90,180,270}`
    /// and we subtract two of them, so raw differences can be ±270. Those MUST
    /// fold to the equivalent ±90 or the file rotates three quarter-turns the
    /// wrong way — precisely the "multiplied" symptom this work replaced.
    func testNormalizedDeltaDegreesFoldsIntoSignedHalfTurn() {
        XCTAssertEqual(OrientationPolicy.normalizedDeltaDegrees(0), 0)
        XCTAssertEqual(OrientationPolicy.normalizedDeltaDegrees(90), 90)
        XCTAssertEqual(OrientationPolicy.normalizedDeltaDegrees(-90), -90)
        XCTAssertEqual(OrientationPolicy.normalizedDeltaDegrees(180), 180)
        // 0 − 270 (portrait reference 270, live 0) must read as +90.
        XCTAssertEqual(OrientationPolicy.normalizedDeltaDegrees(-270), 90)
        // 270 − 0 must read as -90.
        XCTAssertEqual(OrientationPolicy.normalizedDeltaDegrees(270), -90)
        XCTAssertEqual(OrientationPolicy.normalizedDeltaDegrees(360), 0)
        XCTAssertEqual(OrientationPolicy.normalizedDeltaDegrees(-180), 180)
        // Junk in, safe zero out.
        XCTAssertEqual(OrientationPolicy.normalizedDeltaDegrees(.nan), 0)
        XCTAssertEqual(OrientationPolicy.normalizedDeltaDegrees(.infinity), 0)
    }

    /// `AVCaptureConnection.videoRotationAngle` only accepts `{0,90,180,270}`.
    func testNormalizedConnectionAngleStaysInTheAcceptedSet() {
        XCTAssertEqual(OrientationPolicy.normalizedConnectionAngle(0), 0)
        XCTAssertEqual(OrientationPolicy.normalizedConnectionAngle(-90), 270)
        XCTAssertEqual(OrientationPolicy.normalizedConnectionAngle(360), 0)
        XCTAssertEqual(OrientationPolicy.normalizedConnectionAngle(450), 90)
        XCTAssertEqual(OrientationPolicy.normalizedConnectionAngle(-450), 270)
        XCTAssertEqual(OrientationPolicy.normalizedConnectionAngle(.nan), 0)
        for raw in stride(from: -720.0, through: 720.0, by: 90.0) {
            let angle = OrientationPolicy.normalizedConnectionAngle(CGFloat(raw))
            XCTAssertTrue([0, 90, 180, 270].contains(angle), "\(raw) → \(angle)")
        }
    }

    /// A sideways delta composes ON TOP of the verified base — it never
    /// replaces it. Pinning the composed result for the two shapes whose base
    /// differs proves the base still contributes.
    func testSidewaysDeltaComposesOnTopOfTheVerifiedBase() {
        // .classic on a landscape buffer has base +π/2; +90 more = 180.
        let classic = OrientationPolicy.writerTransform(
            for: .classic, captureDeltaDegrees: 90, bufferShape: .landscape)
        XCTAssertEqual(classic.a, -1, accuracy: 1e-9)
        XCTAssertEqual(classic.b, 0, accuracy: 1e-9)
        XCTAssertEqual(classic.c, 0, accuracy: 1e-9)
        XCTAssertEqual(classic.d, -1, accuracy: 1e-9)

        // .wide on a landscape buffer has base identity; +90 = a quarter turn.
        let wide = OrientationPolicy.writerTransform(
            for: .wide, captureDeltaDegrees: 90, bufferShape: .landscape)
        XCTAssertEqual(wide.a, 0, accuracy: 1e-9)
        XCTAssertEqual(wide.b, 1, accuracy: 1e-9)

        // ...and -90 from the same base is the opposite quarter turn, so the
        // two sideways holds can never collapse onto each other.
        let wideOther = OrientationPolicy.writerTransform(
            for: .wide, captureDeltaDegrees: -90, bufferShape: .landscape)
        XCTAssertEqual(wideOther.b, -wide.b, accuracy: 1e-9)
    }

    // MARK: - 3.1 selfie-mirror composition (item 3)

    /// Mirror is applied LAST, flipping the already-upright display frame
    /// about its vertical axis. With an identity base that is a pure x-flip.
    func testMirrorOnIdentityBaseIsPureHorizontalFlip() {
        let t = OrientationPolicy.writerTransform(
            for: .wide, captureDeltaDegrees: 0, bufferShape: .landscape, mirrored: true)
        XCTAssertEqual(t.a, -1, accuracy: 1e-9)
        XCTAssertEqual(t.b, 0, accuracy: 1e-9)
        XCTAssertEqual(t.c, 0, accuracy: 1e-9)
        XCTAssertEqual(t.d, 1, accuracy: 1e-9)
    }

    /// Mirror composed after a +π/2 base gives [0, 1, 1, 0] — still a
    /// dimension-swapping transform, but with a negative determinant.
    func testMirrorAfterQuarterTurnStillSwapsPlaybackDimensions() {
        let t = OrientationPolicy.writerTransform(
            for: .classic, captureDeltaDegrees: 0, bufferShape: .landscape, mirrored: true)
        XCTAssertEqual(t.a, 0, accuracy: 1e-9)
        XCTAssertEqual(t.b, 1, accuracy: 1e-9)
        XCTAssertEqual(t.c, 1, accuracy: 1e-9)
        XCTAssertEqual(t.d, 0, accuracy: 1e-9)

        // The self-test's playback math must survive the flip: a mirrored
        // 4032×3024 landscape buffer still plays 3024×4032 portrait.
        let (w, h) = RecordingSelfTest.playbackDimensions(
            encodedWidth: 4032, encodedHeight: 3024,
            transform: [Double(t.a), Double(t.b), Double(t.c), Double(t.d)]
        )
        XCTAssertEqual(w, 3024)
        XCTAssertEqual(h, 4032)
    }

    /// Mirroring must be an involution: flipping twice is the un-mirrored
    /// transform. Cheap proof that the flip is a clean reflection and hasn't
    /// picked up a rotation component.
    func testMirrorIsItsOwnInverse() {
        for shape in [RecordingAspect.wide, .classic, .square, .openGate] {
            for delta in [CGFloat(0), 90, -90, 180] {
                let plain = OrientationPolicy.writerTransform(
                    for: shape, captureDeltaDegrees: delta, bufferShape: .landscape)
                let mirrored = OrientationPolicy.writerTransform(
                    for: shape, captureDeltaDegrees: delta, bufferShape: .landscape, mirrored: true)
                let twice = mirrored.concatenating(OrientationPolicy.horizontalFlip)
                XCTAssertEqual(twice.a, plain.a, accuracy: 1e-9, "\(shape) Δ\(delta): a")
                XCTAssertEqual(twice.b, plain.b, accuracy: 1e-9, "\(shape) Δ\(delta): b")
                XCTAssertEqual(twice.c, plain.c, accuracy: 1e-9, "\(shape) Δ\(delta): c")
                XCTAssertEqual(twice.d, plain.d, accuracy: 1e-9, "\(shape) Δ\(delta): d")
                // A mirror flips handedness — determinant must change sign.
                let detPlain = plain.a * plain.d - plain.b * plain.c
                let detMirror = mirrored.a * mirrored.d - mirrored.b * mirrored.c
                XCTAssertEqual(detMirror, -detPlain, accuracy: 1e-9, "\(shape) Δ\(delta): determinant")
            }
        }
    }

    // MARK: - previewRotationAngle (always 0°)
    //
    // Post-pass-13e: AVCaptureVideoPreviewLayer applies its own device-
    // orientation-aware rotation when videoRotationAngle == 0. Setting any
    // non-zero value stacks on top of that auto-rotation, breaking it.
    // User testing on iPhone 17 Pro Max + iOS 26.3.1 confirmed:
    //   - 90° on landscape: "rotated 90° to the left" (wrong)
    //   - 270° on landscape: "rotated 90° to the right" (also wrong)
    //   - 0° on square: correct
    // Hence 0° for all (aspect × bufferShape) pairs.

    func testPreviewAngleZeroDeltaMatchesVerifiedSquareFrontSensorRow() {
        let aspects: [RecordingAspect] = [
            .wide, .classic, .square, .openGate
        ]
        let shapes: [OrientationPolicy.BufferShape] = [.landscape, .portrait, .square]
        for aspect in aspects {
            for shape in shapes {
                // Explicit device + explicit zero delta: the verified portrait
                // answer for the iPhone-17 class, unchanged by 3.1.
                XCTAssertEqual(
                    OrientationPolicy.previewRotationAngle(
                        for: aspect, bufferShape: shape,
                        device: .squareFrontSensor, previewDeltaDegrees: 0
                    ),
                    0,
                    "\(aspect) × \(shape) must be 0° at zero delta"
                )
                // ...and the terse 2-arg overload must agree with the explicit
                // zero-delta form for whatever device the test host reports.
                let live = OrientationPolicy.DeviceGenerationHint.from(
                    modelIdentifier: OrientationPolicy.currentDeviceModelIdentifier
                )
                XCTAssertEqual(
                    OrientationPolicy.previewRotationAngle(for: aspect, bufferShape: shape),
                    OrientationPolicy.previewRotationAngle(
                        for: aspect, bufferShape: shape, device: live, previewDeltaDegrees: 0
                    ),
                    "\(aspect) × \(shape): 2-arg overload must be the zero-delta answer"
                )
            }
        }
    }

    /// The preview half of the 3.1 fix: a non-zero coordinator delta rotates
    /// the connection off the verified portrait row, and always lands in the
    /// `{0,90,180,270}` set `AVCaptureConnection` accepts.
    func testPreviewAngleFollowsTheCoordinatorDelta() {
        // squareFrontSensor base is 0, so the delta IS the angle (mod 360).
        XCTAssertEqual(
            OrientationPolicy.previewRotationAngle(
                for: .openGate, bufferShape: .square,
                device: .squareFrontSensor, previewDeltaDegrees: 90),
            90
        )
        XCTAssertEqual(
            OrientationPolicy.previewRotationAngle(
                for: .openGate, bufferShape: .square,
                device: .squareFrontSensor, previewDeltaDegrees: -90),
            270
        )
        XCTAssertEqual(
            OrientationPolicy.previewRotationAngle(
                for: .openGate, bufferShape: .square,
                device: .squareFrontSensor, previewDeltaDegrees: 180),
            180
        )
        // The wideFrontSensor row is a non-zero placeholder; the delta must
        // compose onto it rather than replace it.
        let base = OrientationPolicy.basePreviewRotationAngle(device: .wideFrontSensor)
        XCTAssertEqual(
            OrientationPolicy.previewRotationAngle(
                for: .openGate, bufferShape: .square,
                device: .wideFrontSensor, previewDeltaDegrees: 90),
            OrientationPolicy.normalizedConnectionAngle(base + 90)
        )
        // Every combination stays inside the accepted set.
        for device in [OrientationPolicy.DeviceGenerationHint.squareFrontSensor, .wideFrontSensor, .unknown] {
            for delta in [CGFloat(0), 90, -90, 180, 270, -270] {
                let angle = OrientationPolicy.previewRotationAngle(
                    for: .wide, bufferShape: .portrait, device: device, previewDeltaDegrees: delta)
                XCTAssertTrue([0, 90, 180, 270].contains(angle), "\(device) Δ\(delta) → \(angle)")
            }
        }
    }

    // MARK: - RecordingSelfTest.playbackDimensions (regression)

    func testPlaybackDimsIdentityKeepsEncoded() {
        let identity: [Double] = [1, 0, 0, 1]
        let (w, h) = RecordingSelfTest.playbackDimensions(
            encodedWidth: 2160, encodedHeight: 3840, transform: identity
        )
        XCTAssertEqual(w, 2160)
        XCTAssertEqual(h, 3840)
    }

    func testPlaybackDimsRotationSwapsAxes() {
        // 4032×3024 + +π/2 [0,1,-1,0] → plays 3024×4032 (portrait, correct).
        let rotation: [Double] = [0, 1, -1, 0]
        let (w, h) = RecordingSelfTest.playbackDimensions(
            encodedWidth: 4032, encodedHeight: 3024, transform: rotation
        )
        XCTAssertEqual(w, 3024)
        XCTAssertEqual(h, 4032)
    }

    func testPlaybackDimsBugRegressionTest() {
        // dogfood-pass-10: portrait buffer with non-identity transform
        // sideways-landed playback. Pinned even after subsequent fixes.
        let bugTransform: [Double] = [0, -1, 1, 0]
        let (w, h) = RecordingSelfTest.playbackDimensions(
            encodedWidth: 2160, encodedHeight: 3840, transform: bugTransform
        )
        XCTAssertEqual(w, 3840)
        XCTAssertEqual(h, 2160)
        XCTAssertFalse(h > w, "portrait-playback assertion correctly fails this case")
    }

    // MARK: - Integration: end-to-end orientation predictions (portrait hold)
    //
    // For every (shape × buffer) combo the user can land in with the phone
    // held UPRIGHT (portrait hold — the identity-hold path that reproduces
    // today's verified pipeline), predict the composed writer transform and
    // the resulting playback dims. Acceptance under portrait hold: `.wide`
    // plays landscape (the merged 16:9 shape's upright output); every other
    // shape plays portrait or square.

    func testEndToEndOrientationPredictionsPortraitHold() {
        // (label, shape, bufW, bufH, expPlayW, expPlayH)
        let cases: [(String, RecordingAspect, Int, Int, Int, Int)] = [
            // .wide produces a portrait buffer on iPhone 17 + iOS 26 → +π/2 →
            // 3840×2160 landscape playback (verified 16:9-user-pick output).
            (".wide → portrait buffer → landscape playback", .wide, 2160, 3840, 3840, 2160),
            // .classic (4:3) produces landscape buffer; rotates to portrait.
            (".classic → landscape buffer", .classic, 4032, 3024, 3024, 4032),
            // .square → square buffer, square playback.
            (".square → square buffer", .square, 3024, 3024, 3024, 3024),
            // openGate on iPhone 17 + iOS 26.3.1: ratio1x1 not declared,
            // falls back to ratio4x3 → landscape buffer → rotates to portrait.
            (".openGate landscape fallback (current iPhone 17 + iOS 26.3.1)",
             .openGate, 4032, 3024, 3024, 4032),
            // openGate on a future iOS exposing ratio1x1: square buffer,
            // square playback.
            (".openGate ratio1x1 (future iOS)",
             .openGate, 3024, 3024, 3024, 3024)
        ]
        for c in cases {
            let (label, shape, bufW, bufH, expW, expH) = c
            guard let bufferShape = OrientationPolicy.BufferShape.from(width: bufW, height: bufH) else {
                XCTFail("invalid dims for case \(label)")
                continue
            }
            let xform = OrientationPolicy.writerTransform(
                for: shape, captureDeltaDegrees: 0, bufferShape: bufferShape)
            let transformArray: [Double] = [
                Double(xform.a), Double(xform.b), Double(xform.c), Double(xform.d)
            ]
            let (playW, playH) = RecordingSelfTest.playbackDimensions(
                encodedWidth: bufW, encodedHeight: bufH, transform: transformArray
            )
            XCTAssertEqual(playW, expW, "case \(label): playback width")
            XCTAssertEqual(playH, expH, "case \(label): playback height")
            // Acceptance: .wide plays landscape under upright hold; all other
            // shapes play portrait or square.
            if shape.canonicalShape == .wide {
                XCTAssertGreaterThanOrEqual(
                    playW, playH,
                    "case \(label): .wide upright must play landscape or square"
                )
            } else {
                XCTAssertGreaterThanOrEqual(
                    playH, playW,
                    "case \(label): must play portrait or square under upright hold"
                )
            }
        }
    }

    // MARK: - Self-test helpers

    func testTransformsAreCloseIdentityVsIdentity() {
        let id: [Double] = [1, 0, 0, 1]
        XCTAssertTrue(RecordingSelfTest.transformsAreClose(id, id))
    }

    func testTransformsAreCloseWithFloatingPointNoise() {
        let exact: [Double] = [0, -1, 1, 0]
        let noisy: [Double] = [6.123e-17, -1, 1, 6.123e-17]
        XCTAssertTrue(RecordingSelfTest.transformsAreClose(exact, noisy))
    }

    func testTransformsAreCloseRejectsDifferentTransforms() {
        let identity: [Double] = [1, 0, 0, 1]
        let rotation: [Double] = [0, -1, 1, 0]
        XCTAssertFalse(RecordingSelfTest.transformsAreClose(identity, rotation))
    }

    func testTransformsAreCloseRejectsWrongCount() {
        XCTAssertFalse(RecordingSelfTest.transformsAreClose([1, 0, 0], [1, 0, 0, 1]))
    }

    // MARK: - expectedPlaybackAspectRatio (V3 §07: hold-aware)
    //
    // Playback orientation intent is the HOLD now. Portrait hold → portrait
    // playback; landscape hold → landscape playback.

    func testExpectedPlaybackAspectRatioWidePortraitHoldPortraitBuffer() {
        // .wide, upright hold, portrait buffer 2160×3840 → portrait playback
        // 2160×3840 → ratio = 0.5625 (9:16 vertical).
        XCTAssertEqual(
            RecordingSelfTest.expectedPlaybackAspectRatio(
                for: .wide, hold: .portrait, bufferShape: .portrait,
                bufferWidth: 2160, bufferHeight: 3840
            ),
            9.0 / 16.0,
            accuracy: 1e-9
        )
    }

    func testExpectedPlaybackAspectRatioClassicPortraitHoldLandscapeBuffer() {
        // .classic, upright hold, landscape buffer 4032×3024 rotates →
        // portrait playback 3024×4032 → ratio = 0.75 (3:4).
        XCTAssertEqual(
            RecordingSelfTest.expectedPlaybackAspectRatio(
                for: .classic, hold: .portrait, bufferShape: .landscape,
                bufferWidth: 4032, bufferHeight: 3024
            ),
            3.0 / 4.0,
            accuracy: 1e-9
        )
    }

    func testExpectedPlaybackAspectRatioWideLandscapeHoldLandscapePlayback() {
        // .wide, sideways (landscape) hold, landscape buffer plays landscape.
        // ratio = 4032/2268 = 1.778 (16:9).
        XCTAssertEqual(
            RecordingSelfTest.expectedPlaybackAspectRatio(
                for: .wide, hold: .landscapeLeft, bufferShape: .landscape,
                bufferWidth: 4032, bufferHeight: 2268
            ),
            16.0 / 9.0,
            accuracy: 1e-3
        )
    }

    func testExpectedPlaybackAspectRatioSquarePortraitHold() {
        XCTAssertEqual(
            RecordingSelfTest.expectedPlaybackAspectRatio(
                for: .square, hold: .portrait, bufferShape: .square,
                bufferWidth: 3024, bufferHeight: 3024
            ),
            1.0,
            accuracy: 1e-9
        )
    }

    func testExpectedPlaybackAspectRatioOpenGateLandscapeFallbackPortraitHold() {
        // iPhone 17 + iOS 26.3.1: openGate falls back to ratio4x3 → 4032×3024
        // landscape → rotated to portrait playback 3024×4032 → 0.75 (upright).
        XCTAssertEqual(
            RecordingSelfTest.expectedPlaybackAspectRatio(
                for: .openGate, hold: .portrait, bufferShape: .landscape,
                bufferWidth: 4032, bufferHeight: 3024
            ),
            3.0 / 4.0,
            accuracy: 1e-9
        )
    }

    func testExpectedPlaybackAspectRatioOpenGateSquareFuture() {
        // Future iOS exposing ratio1x1 in supportedDynamicAspectRatios:
        // openGate gets the true square readout → 1.0 (same either hold).
        XCTAssertEqual(
            RecordingSelfTest.expectedPlaybackAspectRatio(
                for: .openGate, hold: .portrait, bufferShape: .square,
                bufferWidth: 3024, bufferHeight: 3024
            ),
            1.0,
            accuracy: 1e-9
        )
    }

    // MARK: - BrightnessGrid

    func testBrightnessGridVerticalGradientTopBright() {
        let g = BrightnessGrid(topLeft: 0.8, topRight: 0.7, bottomLeft: 0.2, bottomRight: 0.3, center: 0.5)
        XCTAssertEqual(g.verticalGradient, 0.5, accuracy: 1e-9)
    }

    func testBrightnessGridVerticalGradientBottomBright() {
        let g = BrightnessGrid(topLeft: 0.2, topRight: 0.3, bottomLeft: 0.8, bottomRight: 0.7, center: 0.5)
        XCTAssertEqual(g.verticalGradient, -0.5, accuracy: 1e-9)
    }

    func testBrightnessGridHorizontalGradientLeftBright() {
        let g = BrightnessGrid(topLeft: 0.8, topRight: 0.2, bottomLeft: 0.7, bottomRight: 0.3, center: 0.5)
        XCTAssertEqual(g.horizontalGradient, 0.5, accuracy: 1e-9)
    }

    func testBrightnessGridUniformReportsZeroGradient() {
        let g = BrightnessGrid(topLeft: 0.5, topRight: 0.5, bottomLeft: 0.5, bottomRight: 0.5, center: 0.5)
        XCTAssertEqual(g.verticalGradient, 0.0, accuracy: 1e-9)
        XCTAssertEqual(g.horizontalGradient, 0.0, accuracy: 1e-9)
    }

    func testBrightnessGridSummaryDescribesUniformAndDirectional() {
        let uniform = BrightnessGrid(topLeft: 0.5, topRight: 0.5, bottomLeft: 0.5, bottomRight: 0.5, center: 0.5)
        XCTAssertTrue(uniform.gradientSummary.contains("uniform"))

        let topBright = BrightnessGrid(topLeft: 0.9, topRight: 0.9, bottomLeft: 0.1, bottomRight: 0.1, center: 0.5)
        XCTAssertTrue(topBright.gradientSummary.contains("top-bright"))

        let leftBright = BrightnessGrid(topLeft: 0.9, topRight: 0.1, bottomLeft: 0.9, bottomRight: 0.1, center: 0.5)
        XCTAssertTrue(leftBright.gradientSummary.contains("left-bright"))
    }
}

// MARK: - RotationCoordinatorBox (3.1 item 4)
//
// The box is the ONLY place that turns Apple's absolute
// `AVCaptureDevice.RotationCoordinator` angles into the deltas the rest of the
// app consumes. A simulator cannot rotate a real camera, so these tests drive
// the same `ingest` path through `_testSetAngles`, which takes the interface
// orientation as an explicit parameter instead of reading the live scene.
//
// The absolute angle values used below (90 in portrait, 0/180 sideways) are
// ILLUSTRATIVE, not pinned: the entire point of the delta design is that the
// absolute values cancel. Every assertion is about a DIFFERENCE.

@MainActor
final class RotationCoordinatorBoxTests: XCTestCase {

    private func makeBox(withLayer: Bool = true) -> RotationCoordinatorBox {
        let box = RotationCoordinatorBox(suppressDeviceWork: true)
        box._testSetPretendBound(true)
        box._testSetHasPreviewLayer(withLayer)
        return box
    }

    /// Nothing observed yet ⇒ no reference ⇒ zero deltas ⇒ downstream gets
    /// today's verified portrait behaviour. This is the "app launched
    /// sideways and has never been upright" case, and it must degrade to
    /// SAFE (uncorrected) rather than to a guess.
    func testUncalibratedBoxPublishesZeroDeltas() {
        let box = makeBox()
        XCTAssertFalse(box.isCalibrated)
        XCTAssertEqual(box.captureDeltaDegrees, 0)
        XCTAssertEqual(box.previewDeltaDegrees, 0)

        // Even after a sideways observation, with no portrait reference we
        // must NOT invent one.
        box._testSetAngles(preview: 180, capture: 0, interfacePortrait: false)
        XCTAssertFalse(box.isCalibrated)
        XCTAssertEqual(box.captureDeltaDegrees, 0)
        XCTAssertEqual(box.previewDeltaDegrees, 0)
    }

    // MARK: - The capture→preview fallback (3.1, device-driven)
    //
    // On iPhone 17 Pro Max / iOS 27, `videoRotationAngleForHorizonLevelPreview`
    // tracks the device while `...ForHorizonLevelCapture` stays pinned at its
    // portrait value, so the writer received a zero correction and landscape
    // files came out 90° off. `captureDeltaDegrees` therefore falls back to the
    // preview delta when its own is zero. These tests exist because the
    // original suite drove `preview:` and `capture:` to the SAME value in every
    // case, so the fallback branch was never reached by any test.

    /// The real device shape: capture pinned, preview moving. The capture delta
    /// must adopt the preview's answer rather than reporting no rotation.
    func testCaptureDeltaFallsBackToPreviewWhenCaptureAngleIsPinned() {
        let box = makeBox()
        box._testSetHasPreviewLayer(true)
        // Upright: both angles latch as the reference.
        box._testSetAngles(preview: 90, capture: 90, interfacePortrait: true)
        XCTAssertEqual(box.captureDeltaDegrees, 0, "Portrait must stay at zero.")

        // Turned sideways: preview moves, capture does not (the device bug).
        box._testSetAngles(preview: 180, capture: 90, interfacePortrait: false)
        XCTAssertEqual(box.previewDeltaDegrees, 90)
        XCTAssertEqual(box.captureDeltaDegrees, 90,
                       "With its own delta pinned at 0, capture must adopt the preview delta.")
    }

    /// The fallback must never manufacture a rotation in portrait — that is the
    /// anti-regression hinge, and the fallback is the one thing that could
    /// break it.
    func testFallbackCannotIntroduceRotationInPortrait() {
        let box = makeBox()
        box._testSetHasPreviewLayer(true)
        box._testSetAngles(preview: 90, capture: 90, interfacePortrait: true)
        XCTAssertEqual(box.captureDeltaDegrees, 0)
        XCTAssertEqual(box.previewDeltaDegrees, 0,
                       "Both references re-latch in portrait, so neither delta can be non-zero.")
    }

    /// Where the capture angle DOES vary (other device classes, future OS), its
    /// own value must win — the preview delta is a fallback, not a replacement.
    func testOwnCaptureDeltaWinsWhenItIsNonZero() {
        let box = makeBox()
        box._testSetHasPreviewLayer(true)
        box._testSetAngles(preview: 90, capture: 90, interfacePortrait: true)
        box._testSetAngles(preview: 180, capture: 180, interfacePortrait: false)
        XCTAssertEqual(box.captureDeltaDegrees, 90,
                       "A working capture angle must not be overridden by the preview.")
    }

    /// No preview layer means the coordinator's preview angle is a meaningless
    /// 0, so the fallback must stay silent rather than differencing garbage.
    func testFallbackStaysZeroWithoutAPreviewLayer() {
        let box = makeBox()
        box._testSetHasPreviewLayer(false)
        box._testSetAngles(preview: 90, capture: 90, interfacePortrait: true)
        box._testSetAngles(preview: 180, capture: 90, interfacePortrait: false)
        XCTAssertEqual(box.previewDeltaDegrees, 0)
        XCTAssertEqual(box.captureDeltaDegrees, 0,
                       "Uncorrected is safe; a differenced meaningless angle is not.")
    }

    /// Observing while the interface is portrait latches the reference and
    /// pins the delta at exactly zero — the anti-regression hinge.
    func testPortraitObservationLatchesReferenceAndZeroesDeltas() {
        let box = makeBox()
        box._testSetAngles(preview: 90, capture: 90, interfacePortrait: true)
        XCTAssertTrue(box.isCalibrated)
        XCTAssertEqual(box.captureDeltaDegrees, 0)
        XCTAssertEqual(box.previewDeltaDegrees, 0)
        XCTAssertEqual(box.referenceCaptureDegrees, 90)
        XCTAssertEqual(box.referencePreviewDegrees, 90)
    }

    /// Rotating sideways after calibration yields the coordinator's own
    /// signed delta — magnitude AND sign from the OS, nothing pinned by us.
    func testSidewaysDeltaIsTheDifferenceFromThePortraitReference() {
        let box = makeBox()
        box._testSetAngles(preview: 90, capture: 90, interfacePortrait: true)
        box._testSetAngles(preview: 180, capture: 180, interfacePortrait: false)
        XCTAssertEqual(box.captureDeltaDegrees, 90)
        XCTAssertEqual(box.previewDeltaDegrees, 90)

        // The other sideways hold is the opposite sign, without us saying so.
        box._testSetAngles(preview: 0, capture: 0, interfacePortrait: false)
        XCTAssertEqual(box.captureDeltaDegrees, -90)
        XCTAssertEqual(box.previewDeltaDegrees, -90)
    }

    /// The reference cancels whatever absolute zero point the OS uses. Same
    /// physical rotation, three different absolute conventions, one answer.
    func testAbsoluteAngleConventionCancelsOut() {
        for portraitReference in [CGFloat(0), 90, 180, 270] {
            let box = makeBox()
            box._testSetAngles(
                preview: portraitReference, capture: portraitReference, interfacePortrait: true)
            let sideways = OrientationPolicy.normalizedConnectionAngle(portraitReference + 90)
            box._testSetAngles(preview: sideways, capture: sideways, interfacePortrait: false)
            XCTAssertEqual(box.captureDeltaDegrees, 90,
                           "reference \(portraitReference) must not change the delta")
        }
    }

    /// Wrap-around: a reference of 270 with a live angle of 0 is a +90 turn,
    /// not a -270 one. Getting this wrong is three quarter-turns of error —
    /// the exact "multiplied" symptom the 3.1 work replaced.
    func testDeltaFoldsAcrossTheWrapPoint() {
        let box = makeBox()
        box._testSetAngles(preview: 270, capture: 270, interfacePortrait: true)
        box._testSetAngles(preview: 0, capture: 0, interfacePortrait: false)
        XCTAssertEqual(box.captureDeltaDegrees, 90)
        XCTAssertEqual(box.previewDeltaDegrees, 90)
    }

    /// Returning to portrait re-latches, so the delta snaps back to zero even
    /// if the OS's absolute angle drifted (different device, different camera).
    func testReturningToPortraitReLatchesToZero() {
        let box = makeBox()
        box._testSetAngles(preview: 90, capture: 90, interfacePortrait: true)
        box._testSetAngles(preview: 180, capture: 180, interfacePortrait: false)
        XCTAssertEqual(box.captureDeltaDegrees, 90)
        box._testSetAngles(preview: 270, capture: 270, interfacePortrait: true)
        XCTAssertEqual(box.captureDeltaDegrees, 0)
        XCTAssertEqual(box.previewDeltaDegrees, 0)
    }

    /// ROTATION LOCK. With the interface pinned portrait, every observation
    /// re-latches, so the delta stays 0 and recordings stay portrait — today's
    /// behaviour, which is what locking rotation asks for.
    func testRotationLockedInterfaceKeepsDeltasAtZero() {
        let box = makeBox()
        for capture in [CGFloat(90), 180, 270, 0, 90] {
            box._testSetAngles(preview: capture, capture: capture, interfacePortrait: true)
            XCTAssertEqual(box.captureDeltaDegrees, 0, "locked interface, capture \(capture)")
        }
    }

    /// With no preview layer in the hierarchy the coordinator documents that
    /// its preview angle is a meaningless 0, so we must neither latch it as a
    /// reference nor difference against one. The CAPTURE half is layer-
    /// independent and must keep working.
    func testPreviewDeltaIsSuppressedWithoutALayerButCaptureIsNot() {
        let box = makeBox(withLayer: false)
        box._testSetAngles(preview: 0, capture: 90, interfacePortrait: true)
        XCTAssertNil(box.referencePreviewDegrees)
        XCTAssertEqual(box.referenceCaptureDegrees, 90)

        box._testSetAngles(preview: 0, capture: 180, interfacePortrait: false)
        XCTAssertEqual(box.previewDeltaDegrees, 0, "no layer ⇒ no preview delta")
        XCTAssertEqual(box.captureDeltaDegrees, 90, "capture delta is layer-independent")
    }

    /// An unbound box (camera off) publishes nothing, whatever it last saw.
    func testUnboundBoxPublishesZeroDeltas() {
        let box = makeBox()
        box._testSetAngles(preview: 90, capture: 90, interfacePortrait: true)
        box._testSetAngles(preview: 180, capture: 180, interfacePortrait: false)
        XCTAssertEqual(box.captureDeltaDegrees, 90)
        box._testSetPretendBound(false)
        XCTAssertEqual(box.captureDeltaDegrees, 0)
        XCTAssertEqual(box.previewDeltaDegrees, 0)
    }

    /// Angle observers are how the preview connection learns to re-apply its
    /// rotation without a SwiftUI round trip. Registration fires immediately
    /// (so a late registrant catches up) and again on every change.
    func testAngleObserverFiresOnRegistrationAndOnChange() {
        let box = makeBox()
        let owner = NSObject()
        var fires = 0
        box.addAngleObserver(owner) { fires += 1 }
        XCTAssertEqual(fires, 1, "registration must fire once immediately")
        box._testSetAngles(preview: 90, capture: 90, interfacePortrait: true)
        XCTAssertEqual(fires, 2)
        box.removeAngleObserver(owner)
        box._testSetAngles(preview: 180, capture: 180, interfacePortrait: false)
        XCTAssertEqual(fires, 2, "removed observer must not fire")
    }

    /// End-to-end through the policy: a calibrated box driven sideways must
    /// produce a writer transform that differs from the portrait one, and a
    /// portrait box must reproduce the verified base exactly.
    func testBoxDeltaFeedsThePolicyEndToEnd() {
        let box = makeBox()
        box._testSetAngles(preview: 90, capture: 90, interfacePortrait: true)
        let portrait = OrientationPolicy.writerTransform(
            for: .classic, captureDeltaDegrees: box.captureDeltaDegrees, bufferShape: .landscape)
        XCTAssertEqual(portrait, OrientationPolicy.writerTransform(for: .classic, bufferShape: .landscape))

        box._testSetAngles(preview: 180, capture: 180, interfacePortrait: false)
        let sideways = OrientationPolicy.writerTransform(
            for: .classic, captureDeltaDegrees: box.captureDeltaDegrees, bufferShape: .landscape)
        XCTAssertNotEqual(sideways, portrait, "a sideways hold must change the transform")
    }
}

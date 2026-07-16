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

    // MARK: - V3 §07 MANDATORY anti-regression guard
    //
    // The single load-bearing guarantee: the portrait-hold 3-arg composition
    // MUST equal the verified 2-arg transform for every (shape × bufferShape)
    // cell. If auto-orientation ever changes portrait output — the one thing
    // V3 §07 forbids — this fails at unit-test time, before any device build.
    // The safety argument is `x ∘ identity == x`.

    func testPortraitHoldEqualsVerifiedBaseForEveryShape() {
        let shapes: [RecordingAspect] = [.wide, .classic, .square, .openGate]
        let buffers: [OrientationPolicy.BufferShape] = [.portrait, .landscape, .square]
        for shape in shapes {
            for buffer in buffers {
                let verified = OrientationPolicy.writerTransform(       // 2-arg, untouched
                    for: shape, bufferShape: buffer)
                let composed = OrientationPolicy.writerTransform(       // 3-arg, portrait hold
                    for: shape, hold: .portrait, bufferShape: buffer)
                XCTAssertEqual(composed.a, verified.a, accuracy: 0.0001, "\(shape) × \(buffer): a")
                XCTAssertEqual(composed.b, verified.b, accuracy: 0.0001, "\(shape) × \(buffer): b")
                XCTAssertEqual(composed.c, verified.c, accuracy: 0.0001, "\(shape) × \(buffer): c")
                XCTAssertEqual(composed.d, verified.d, accuracy: 0.0001, "\(shape) × \(buffer): d")
            }
        }
    }

    /// The merged `.wide` (raw "ratio16x9") on a portrait buffer must still be
    /// +π/2 — the verified 16:9-user-pick value. Guards §2.3's raw-value reuse
    /// against a "cleanup" that flips `.wide` into the portrait-intent branch.
    func testWideShapePortraitBufferIsVerifiedPlusPiOverTwo() {
        let t = OrientationPolicy.writerTransform(
            for: .wide, hold: .portrait, bufferShape: .portrait)
        XCTAssertEqual(t.a, 0, accuracy: 0.0001)
        XCTAssertEqual(t.b, 1, accuracy: 0.0001)   // +π/2 rotation: a=0,b=1,c=-1,d=0
        XCTAssertEqual(t.c, -1, accuracy: 0.0001)
        XCTAssertEqual(t.d, 0, accuracy: 0.0001)
    }

    /// The downgrade-safety alias must resolve to the same output as `.wide`.
    func testLegacyVerticalAliasResolvesToWide() {
        for buffer in [OrientationPolicy.BufferShape.portrait, .landscape, .square] {
            let aliased = OrientationPolicy.writerTransform(
                for: .legacyVertical9x16, hold: .portrait, bufferShape: buffer)
            let wide = OrientationPolicy.writerTransform(
                for: .wide, hold: .portrait, bufferShape: buffer)
            XCTAssertEqual(aliased.a, wide.a, accuracy: 0.0001, "\(buffer): a")
            XCTAssertEqual(aliased.b, wide.b, accuracy: 0.0001, "\(buffer): b")
            XCTAssertEqual(aliased.c, wide.c, accuracy: 0.0001, "\(buffer): c")
            XCTAssertEqual(aliased.d, wide.d, accuracy: 0.0001, "\(buffer): d")
        }
    }

    /// holdRotation(.portrait) is identity — the composition hinge.
    func testHoldRotationPortraitIsIdentity() {
        XCTAssertTrue(OrientationPolicy.holdRotation(for: .portrait).isIdentity)
    }

    /// The landscape holds compose a non-identity ±π/2 on top of the base.
    /// We assert the constants' magnitude (both are ±π/2) and that they are
    /// opposite handedness — NOT a specific sign, which ships UNVERIFIED and
    /// is pinned on device (§5). Locking a sign here would freeze a guess.
    func testLandscapeHoldRotationsAreOppositeSignedRightAngles() {
        let left = OrientationPolicy.holdRotation(for: .landscapeLeft)
        let right = OrientationPolicy.holdRotation(for: .landscapeRight)
        // A ±90° rotation has a=0, d=0, |b|=1, |c|=1.
        for (label, t) in [("left", left), ("right", right)] {
            XCTAssertEqual(t.a, 0, accuracy: 0.0001, "\(label): a")
            XCTAssertEqual(t.d, 0, accuracy: 0.0001, "\(label): d")
            XCTAssertEqual(abs(t.b), 1, accuracy: 0.0001, "\(label): |b|")
            XCTAssertEqual(abs(t.c), 1, accuracy: 0.0001, "\(label): |c|")
        }
        // Opposite handedness: left.b and right.b have opposite signs.
        XCTAssertEqual(left.b, -right.b, accuracy: 0.0001,
                       "landscapeLeft and landscapeRight must be opposite handedness")
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

    func testPreviewAngleAlwaysZero() {
        let aspects: [RecordingAspect] = [
            .wide, .classic, .square, .openGate
        ]
        let shapes: [OrientationPolicy.BufferShape] = [.landscape, .portrait, .square]
        for aspect in aspects {
            for shape in shapes {
                XCTAssertEqual(
                    OrientationPolicy.previewRotationAngle(for: aspect, bufferShape: shape),
                    0,
                    "\(aspect) × \(shape) must be 0° — let AVCaptureVideoPreviewLayer auto-handle"
                )
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
                for: shape, hold: .portrait, bufferShape: bufferShape)
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

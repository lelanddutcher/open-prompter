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

    // MARK: - wantsPortraitPlayback intent classification

    func testWantsPortraitPlaybackIntent() {
        XCTAssertTrue(OrientationPolicy.wantsPortraitPlayback(for: .ratio9x16))
        XCTAssertTrue(OrientationPolicy.wantsPortraitPlayback(for: .ratio4x3))
        XCTAssertTrue(OrientationPolicy.wantsPortraitPlayback(for: .ratio1x1))
        XCTAssertTrue(OrientationPolicy.wantsPortraitPlayback(for: .openGate))
        XCTAssertFalse(OrientationPolicy.wantsPortraitPlayback(for: .ratio16x9))
    }

    // MARK: - writerTransform (aspect × bufferShape)

    func testWriterTransformPortraitIntentLandscapeBufferRotates() {
        // openGate falling back to ratio4x3 on iPhone 17 + iOS 26.3.1 → 4032×3024
        // landscape. Want portrait playback → +π/2 rotation.
        for aspect in [RecordingAspect.openGate, .ratio4x3, .ratio9x16, .ratio1x1] {
            let t = OrientationPolicy.writerTransform(for: aspect, bufferShape: .landscape)
            XCTAssertEqual(t.a, 0, accuracy: 1e-6, "\(aspect): a")
            XCTAssertEqual(t.b, 1, accuracy: 1e-6, "\(aspect): b")
            XCTAssertEqual(t.c, -1, accuracy: 1e-6, "\(aspect): c")
            XCTAssertEqual(t.d, 0, accuracy: 1e-6, "\(aspect): d")
        }
    }

    func testWriterTransformPortraitIntentPortraitBufferIdentity() {
        // ratio9x16 produces a 2160×3840 portrait buffer when iOS reshapes
        // pixel content; identity ships device-upright playback (iOS already
        // rotated pixels during the reshape).
        for aspect in [RecordingAspect.ratio9x16, .ratio4x3, .openGate] {
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
        for aspect in [RecordingAspect.ratio1x1, .openGate] {
            let t = OrientationPolicy.writerTransform(for: aspect, bufferShape: .square)
            XCTAssertEqual(t.a, 0, accuracy: 1e-6, "\(aspect) on square: a")
            XCTAssertEqual(t.b, 1, accuracy: 1e-6, "\(aspect) on square: b")
            XCTAssertEqual(t.c, -1, accuracy: 1e-6, "\(aspect) on square: c")
            XCTAssertEqual(t.d, 0, accuracy: 1e-6, "\(aspect) on square: d")
        }
    }

    func testWriterTransformLandscapeIntentLandscapeBufferIdentity() {
        // ratio16x9 wants landscape playback; landscape buffer → identity.
        let t = OrientationPolicy.writerTransform(for: .ratio16x9, bufferShape: .landscape)
        XCTAssertEqual(t, .identity)
    }

    func testWriterTransformLandscapeIntentPortraitBufferReverseRotates() {
        // 16:9 + portrait buffer → -π/2 to land landscape playback. Edge
        // case; iOS shouldn't normally produce a portrait buffer for ratio16x9.
        let t = OrientationPolicy.writerTransform(for: .ratio16x9, bufferShape: .portrait)
        XCTAssertEqual(t.a, 0, accuracy: 1e-6)
        XCTAssertEqual(t.b, -1, accuracy: 1e-6)
        XCTAssertEqual(t.c, 1, accuracy: 1e-6)
        XCTAssertEqual(t.d, 0, accuracy: 1e-6)
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
            .ratio9x16, .ratio4x3, .ratio16x9, .ratio1x1, .openGate
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

    // MARK: - Integration: end-to-end orientation predictions
    //
    // For every (aspect × buffer) combo the user can land in, predict the
    // policy's writer transform and the resulting playback dims. Acceptance:
    // portrait-intent aspects play portrait or square; ratio16x9 plays
    // landscape.

    func testEndToEndOrientationPredictions() {
        // (label, aspect, bufW, bufH, expPlayW, expPlayH)
        let cases: [(String, RecordingAspect, Int, Int, Int, Int)] = [
            // ratio9x16 produces portrait buffer on iPhone 17 + iOS 26.
            (".ratio9x16 → portrait buffer", .ratio9x16, 2160, 3840, 2160, 3840),
            // ratio4x3 produces landscape buffer; rotates to portrait.
            (".ratio4x3 → landscape buffer", .ratio4x3, 4032, 3024, 3024, 4032),
            // ratio16x9 (landscape intent) plays landscape.
            (".ratio16x9 → landscape playback", .ratio16x9, 4032, 2268, 4032, 2268),
            // ratio1x1 → square buffer, square playback.
            (".ratio1x1 → square buffer", .ratio1x1, 3024, 3024, 3024, 3024),
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
            let (label, aspect, bufW, bufH, expW, expH) = c
            guard let shape = OrientationPolicy.BufferShape.from(width: bufW, height: bufH) else {
                XCTFail("invalid dims for case \(label)")
                continue
            }
            let xform = OrientationPolicy.writerTransform(for: aspect, bufferShape: shape)
            let transformArray: [Double] = [
                Double(xform.a), Double(xform.b), Double(xform.c), Double(xform.d)
            ]
            let (playW, playH) = RecordingSelfTest.playbackDimensions(
                encodedWidth: bufW, encodedHeight: bufH, transform: transformArray
            )
            XCTAssertEqual(playW, expW, "case \(label): playback width")
            XCTAssertEqual(playH, expH, "case \(label): playback height")
            // Acceptance per intent:
            if OrientationPolicy.wantsPortraitPlayback(for: aspect) {
                XCTAssertGreaterThanOrEqual(
                    playH, playW,
                    "case \(label): portrait-intent must play portrait or square"
                )
            } else {
                XCTAssertGreaterThanOrEqual(
                    playW, playH,
                    "case \(label): landscape-intent (16:9) must play landscape or square"
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

    // MARK: - expectedPlaybackAspectRatio (buffer-shape-aware)

    func testExpectedPlaybackAspectRatio9x16Portrait() {
        // Portrait buffer 2160×3840 with portrait-intent → playback 2160×3840
        // → ratio = 2160/3840 = 0.5625 (9:16)
        XCTAssertEqual(
            RecordingSelfTest.expectedPlaybackAspectRatio(
                for: .ratio9x16, bufferShape: .portrait,
                bufferWidth: 2160, bufferHeight: 3840
            ),
            9.0 / 16.0,
            accuracy: 1e-9
        )
    }

    func testExpectedPlaybackAspectRatio4x3LandscapeBuffer() {
        // Landscape 4032×3024 with portrait-intent rotates → playback 3024×4032
        // → ratio = 3024/4032 = 0.75 (3:4)
        XCTAssertEqual(
            RecordingSelfTest.expectedPlaybackAspectRatio(
                for: .ratio4x3, bufferShape: .landscape,
                bufferWidth: 4032, bufferHeight: 3024
            ),
            3.0 / 4.0,
            accuracy: 1e-9
        )
    }

    func testExpectedPlaybackAspectRatio16x9LandscapeBufferLandscapePlayback() {
        // 16:9 is landscape intent — landscape buffer plays landscape.
        // ratio = 4032/2268 = 1.778 (16:9)
        XCTAssertEqual(
            RecordingSelfTest.expectedPlaybackAspectRatio(
                for: .ratio16x9, bufferShape: .landscape,
                bufferWidth: 4032, bufferHeight: 2268
            ),
            16.0 / 9.0,
            accuracy: 1e-3
        )
    }

    func testExpectedPlaybackAspectRatio1x1Square() {
        XCTAssertEqual(
            RecordingSelfTest.expectedPlaybackAspectRatio(
                for: .ratio1x1, bufferShape: .square,
                bufferWidth: 3024, bufferHeight: 3024
            ),
            1.0,
            accuracy: 1e-9
        )
    }

    func testExpectedPlaybackAspectRatioOpenGateLandscapeFallback() {
        // iPhone 17 + iOS 26.3.1: openGate falls back to ratio4x3 → 4032×3024
        // landscape → rotated to portrait playback 3024×4032 → 0.75
        XCTAssertEqual(
            RecordingSelfTest.expectedPlaybackAspectRatio(
                for: .openGate, bufferShape: .landscape,
                bufferWidth: 4032, bufferHeight: 3024
            ),
            3.0 / 4.0,
            accuracy: 1e-9
        )
    }

    func testExpectedPlaybackAspectRatioOpenGateSquareFuture() {
        // Future iOS exposing ratio1x1 in supportedDynamicAspectRatios:
        // openGate gets the true square readout → 1.0
        XCTAssertEqual(
            RecordingSelfTest.expectedPlaybackAspectRatio(
                for: .openGate, bufferShape: .square,
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

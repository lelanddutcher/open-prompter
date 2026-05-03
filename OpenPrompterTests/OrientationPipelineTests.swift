//
//  OrientationPipelineTests.swift
//  OpenPrompterTests
//
//  Pinned coverage of the rotation/orientation pipeline. The dogfood-pass-10
//  bug was a portrait buffer (iOS 26 .ratio9x16 → 2160×3840) double-rotated
//  by an unconditional writer-side `-π/2` transform → sideways landscape
//  playback. The dogfood-pass-11 follow-up moved rotation source-of-truth
//  from buffer-dim inference to the user's picker aspect via
//  `OrientationPolicy`, eliminating the cold-start `dynamicDimensions ==
//  (0,0)` race that mis-picked rotations on first launch.
//
//  These tests pin the corrected behaviour:
//
//    1. `OrientationPolicy.writerTransform(for:)` — per-aspect lookup
//       drives the writer's `videoInput.transform`. `.ratio9x16` /
//       `.ratio1x1` / `.openGate` get identity; `.ratio4x3` / `.ratio16x9`
//       get +π/2 (the sign update is the dogfood-pass-11 fix for the
//       upside-down 4:3 user report).
//    2. `OrientationPolicy.previewRotationAngle(for:)` — per-aspect
//       lookup drives the preview connection's `videoRotationAngle`.
//       `.ratio9x16` and `.ratio1x1` → 0°; landscape aspects → 90°.
//    3. `RecordingSelfTest.playbackDimensions(...)` — composes encoded dims
//       with `preferredTransform` to compute display orientation. The
//       dogfood-pass-10 regression test stays — same buffer dim + transform
//       still has to fail the portrait-playback assertion.
//
//  Plus an integration check that the policy's writer transform produces
//  portrait-or-square playback for every aspect+buffer combination the
//  user can land in.
//

import XCTest
import CoreGraphics
@testable import OpenPrompter

final class OrientationPipelineTests: XCTestCase {

    // MARK: - OrientationPolicy.writerTransform (per-aspect)

    func testWriterTransformRatio9x16IsIdentity() {
        // .ratio9x16: iOS 26 reshapes to 2160×3840 portrait. Identity is
        // correct — buffer is already portrait, rotation would sideways-
        // land it (dogfood-pass-10 symptom).
        let t = OrientationPolicy.writerTransform(for: .ratio9x16)
        XCTAssertEqual(t, .identity)
    }

    func testWriterTransformRatio1x1IsIdentity() {
        // .ratio1x1: square buffer, rotation is a visual no-op. Identity
        // is the cleaner metadata for players.
        let t = OrientationPolicy.writerTransform(for: .ratio1x1)
        XCTAssertEqual(t, .identity)
    }

    func testWriterTransformOpenGateIsIdentity() {
        // .openGate: iPhone 17 1×1 sensor → square buffer (identity is
        // correct). Older 4:3 sensors would need -π/2 — accepted as a
        // known-issue per OrientationPolicy.swift's TODO; the policy is
        // tuned for the primary user's iPhone 17.
        let t = OrientationPolicy.writerTransform(for: .openGate)
        XCTAssertEqual(t, .identity)
    }

    func testWriterTransformRatio4x3IsPositivePiOverTwo() {
        // .ratio4x3: dogfood-pass-11 user report flipped the previous
        // -π/2 to +π/2 to fix upside-down playback. The sign update
        // provides the missing 180° on iPhone 17 + iOS 26 1×1-reshape-to-
        // 4:3 with bottom-up sensor scan.
        let t = OrientationPolicy.writerTransform(for: .ratio4x3)
        XCTAssertEqual(t.a, 0, accuracy: 1e-6)
        XCTAssertEqual(t.b, 1, accuracy: 1e-6)
        XCTAssertEqual(t.c, -1, accuracy: 1e-6)
        XCTAssertEqual(t.d, 0, accuracy: 1e-6)
    }

    func testWriterTransformRatio16x9IsPositivePiOverTwo() {
        // .ratio16x9: same family as .ratio4x3 — landscape reshape from
        // the same 1×1 sensor. Match its convention until proven different.
        let t = OrientationPolicy.writerTransform(for: .ratio16x9)
        XCTAssertEqual(t.a, 0, accuracy: 1e-6)
        XCTAssertEqual(t.b, 1, accuracy: 1e-6)
        XCTAssertEqual(t.c, -1, accuracy: 1e-6)
        XCTAssertEqual(t.d, 0, accuracy: 1e-6)
    }

    // MARK: - OrientationPolicy.previewRotationAngle (per-aspect)

    func testPreviewAngleRatio9x16Is0() {
        // Portrait buffer → don't rotate; already upright in display space.
        XCTAssertEqual(
            OrientationPolicy.previewRotationAngle(for: .ratio9x16),
            0
        )
    }

    func testPreviewAngleRatio1x1Is0() {
        // Square — rotation is a no-op; pick 0 for consistency with the
        // writer's identity transform.
        XCTAssertEqual(
            OrientationPolicy.previewRotationAngle(for: .ratio1x1),
            0
        )
    }

    func testPreviewAngleRatio4x3Is90() {
        // Landscape buffer → 90° to undo landscape sensor scan.
        XCTAssertEqual(
            OrientationPolicy.previewRotationAngle(for: .ratio4x3),
            90
        )
    }

    func testPreviewAngleRatio16x9Is90() {
        // Same family as .ratio4x3.
        XCTAssertEqual(
            OrientationPolicy.previewRotationAngle(for: .ratio16x9),
            90
        )
    }

    func testPreviewAngleOpenGateIs90() {
        // Square (iPhone 17) is no-op visually under either choice; older
        // 4:3 needs 90°. Default 90° to support legacy devices.
        XCTAssertEqual(
            OrientationPolicy.previewRotationAngle(for: .openGate),
            90
        )
    }

    // MARK: - RecordingSelfTest.playbackDimensions (regression)

    func testPlaybackDimsIdentityKeepsEncoded() {
        // 2160×3840 + identity → plays 2160×3840 (portrait, correct).
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
        // The dogfood-pass-10 self-test reported: encoded 2160×3840 with
        // transform [0,-1,1,0]. That played as sideways landscape. Compute
        // what playback dims this would have shown the user — 3840×2160
        // (landscape) — and assert that the new self-test assertion would
        // catch it (playbackHeight > playbackWidth would be FALSE).
        // Pinned even after the dogfood-pass-11 sign flip because the bug
        // shape (portrait buffer + non-identity transform) is the same
        // regardless of sign.
        let bugTransform: [Double] = [0, -1, 1, 0]
        let (w, h) = RecordingSelfTest.playbackDimensions(
            encodedWidth: 2160, encodedHeight: 3840, transform: bugTransform
        )
        XCTAssertEqual(w, 3840, "bug regression: dogfood-pass-10 played 3840 wide")
        XCTAssertEqual(h, 2160, "bug regression: dogfood-pass-10 played 2160 tall")
        XCTAssertFalse(h > w, "the new portrait-playback assertion would fail this case (correctly)")
    }

    // MARK: - Integration: end-to-end orientation predictions

    /// For each aspect the user can pick, predict (a) what transform
    /// `OrientationPolicy.writerTransform(for:)` chooses and (b) what the
    /// resulting file would play as via `playbackDimensions`. Acceptance
    /// criteria for a known-good build: every aspect's playback orientation
    /// is portrait (or square for `.ratio1x1`).
    func testEndToEndOrientationPredictions() {
        // (label, aspect, bufferW, bufferH, expectedPlaybackW, expectedPlaybackH)
        // bufferW/bufferH represent the encoded sample-buffer dims that
        // each aspect produces on iPhone 17 + iOS 26 (the primary user's
        // device). The legacy openGate landscape row is a known-issue per
        // OrientationPolicy.swift; we don't include it here because the
        // policy doesn't currently honor it (TODO in OrientationPolicy.swift).
        let cases: [(String, RecordingAspect, Int, Int, Int, Int)] = [
            (".ratio9x16 (iOS 26)", .ratio9x16, 2160, 3840, 2160, 3840),
            (".ratio4x3", .ratio4x3, 4032, 3024, 3024, 4032),
            (".ratio16x9", .ratio16x9, 4032, 2268, 2268, 4032),
            (".ratio1x1 (iPhone 17 sensor)", .ratio1x1, 3024, 3024, 3024, 3024),
            (".openGate iPhone17 1×1", .openGate, 3024, 3024, 3024, 3024)
        ]
        for c in cases {
            let (label, aspect, bufW, bufH, expW, expH) = c
            let xform = OrientationPolicy.writerTransform(for: aspect)
            // Convert CGAffineTransform back to [a,b,c,d] for the playback
            // helper (matches RecordingSelfTest's serialized shape).
            let transformArray: [Double] = [
                Double(xform.a), Double(xform.b), Double(xform.c), Double(xform.d)
            ]
            let (playW, playH) = RecordingSelfTest.playbackDimensions(
                encodedWidth: bufW, encodedHeight: bufH, transform: transformArray
            )
            XCTAssertEqual(playW, expW, "case \(label): playback width")
            XCTAssertEqual(playH, expH, "case \(label): playback height")
            // Final acceptance: every aspect plays at least square-or-taller
            // (no aspect should produce sideways landscape playback).
            XCTAssertGreaterThanOrEqual(playH, playW, "case \(label): plays portrait or square")
        }
    }

    // MARK: - Self-test helpers (dogfood-pass-12 robustness additions)

    func testTransformsAreCloseIdentityVsIdentity() {
        let id: [Double] = [1, 0, 0, 1]
        XCTAssertTrue(RecordingSelfTest.transformsAreClose(id, id))
    }

    func testTransformsAreCloseWithFloatingPointNoise() {
        // CGAffineTransform(rotationAngle:) emits ~6e-17 in components that
        // should be exactly 0. The tolerance must absorb that noise.
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

    func testExpectedPlaybackAspectRatio9x16() {
        // 9:16 portrait → 0.5625
        XCTAssertEqual(
            RecordingSelfTest.expectedPlaybackAspectRatio(for: .ratio9x16),
            9.0 / 16.0,
            accuracy: 1e-9
        )
    }

    func testExpectedPlaybackAspectRatio4x3IsPortrait() {
        // 4:3 landscape buffer rotated to portrait playback → 3:4 = 0.75
        XCTAssertEqual(
            RecordingSelfTest.expectedPlaybackAspectRatio(for: .ratio4x3),
            3.0 / 4.0,
            accuracy: 1e-9
        )
    }

    func testExpectedPlaybackAspectRatio16x9IsPortrait() {
        // 16:9 landscape buffer rotated to portrait playback → 9:16 = 0.5625
        XCTAssertEqual(
            RecordingSelfTest.expectedPlaybackAspectRatio(for: .ratio16x9),
            9.0 / 16.0,
            accuracy: 1e-9
        )
    }

    func testExpectedPlaybackAspectRatio1x1IsSquare() {
        XCTAssertEqual(
            RecordingSelfTest.expectedPlaybackAspectRatio(for: .ratio1x1),
            1.0,
            accuracy: 1e-9
        )
    }

    func testExpectedPlaybackAspectRatioOpenGateIsZeroSentinel() {
        // .openGate is device-dependent; the helper returns 0 to signal
        // "skip the aspect-ratio check." The self-test consumer must
        // recognize 0 as "don't assert."
        XCTAssertEqual(
            RecordingSelfTest.expectedPlaybackAspectRatio(for: .openGate),
            0.0
        )
    }

    func testBrightnessGridVerticalGradientTopBright() {
        let g = BrightnessGrid(topLeft: 0.8, topRight: 0.7, bottomLeft: 0.2, bottomRight: 0.3, center: 0.5)
        // Top average 0.75, bottom average 0.25, gradient = +0.5
        XCTAssertEqual(g.verticalGradient, 0.5, accuracy: 1e-9)
    }

    func testBrightnessGridVerticalGradientBottomBright() {
        let g = BrightnessGrid(topLeft: 0.2, topRight: 0.3, bottomLeft: 0.8, bottomRight: 0.7, center: 0.5)
        // Top average 0.25, bottom average 0.75, gradient = -0.5
        XCTAssertEqual(g.verticalGradient, -0.5, accuracy: 1e-9)
    }

    func testBrightnessGridHorizontalGradientLeftBright() {
        let g = BrightnessGrid(topLeft: 0.8, topRight: 0.2, bottomLeft: 0.7, bottomRight: 0.3, center: 0.5)
        // Left average 0.75, right average 0.25, gradient = +0.5
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

//
//  OrientationPipelineTests.swift
//  OpenPrompterTests
//
//  Pinned coverage of the rotation/orientation pipeline. The dogfood-pass-10
//  bug was a portrait buffer (iOS 26 .ratio9x16 → 2160×3840) double-rotated
//  by an unconditional writer-side `-π/2` transform → sideways landscape
//  playback. These tests pin the corrected behaviour:
//
//    1. `RecordingSession.writerTransform(forBufferWidth:height:)` —
//       landscape buffers get -π/2, portrait/square get identity.
//    2. `PreviewView.previewRotationAngle(forBufferWidth:height:)` —
//       landscape buffers get 90°, portrait/square get 0°.
//    3. `RecordingSelfTest.playbackDimensions(...)` — composes encoded dims
//       with `preferredTransform` to compute display orientation.
//
//  Plus an integration check that the corrected writer transform + the
//  corrected self-test assertion compose into the predictions in the
//  audit's test matrix (9:16 → identity → portrait playback; 4:3 → -π/2
//  → portrait playback; 1:1 → identity → square playback; the dogfood-
//  pass-10 BUG state — portrait buffer + -π/2 — fails the assertion
//  exactly as it should).
//

import XCTest
import CoreGraphics
@testable import OpenPrompter

final class OrientationPipelineTests: XCTestCase {

    // MARK: - RecordingSession.writerTransform

    func testWriterTransformLandscapeIsNegativePiOverTwo() {
        // 4032×3024 — native iPhone 17 front Ultra Wide 4:3 sensor, also
        // iOS 26 .ratio4x3 reshape output.
        let t = RecordingSession.writerTransform(forBufferWidth: 4032, height: 3024)
        XCTAssertEqual(t.a, 0, accuracy: 1e-6)
        XCTAssertEqual(t.b, -1, accuracy: 1e-6)
        XCTAssertEqual(t.c, 1, accuracy: 1e-6)
        XCTAssertEqual(t.d, 0, accuracy: 1e-6)
    }

    func testWriterTransformWideLandscapeIsNegativePiOverTwo() {
        // 4032×2268 — iOS 26 .ratio16x9 reshape output.
        let t = RecordingSession.writerTransform(forBufferWidth: 4032, height: 2268)
        XCTAssertEqual(t.a, 0, accuracy: 1e-6)
        XCTAssertEqual(t.b, -1, accuracy: 1e-6)
    }

    func testWriterTransformPortraitIsIdentity() {
        // 2160×3840 — iOS 26 .ratio9x16 reshape output. This is the
        // dogfood-pass-10 self-test ground-truth dim that exposed the
        // unconditional-rotation bug; portrait must NOT be rotated again.
        let t = RecordingSession.writerTransform(forBufferWidth: 2160, height: 3840)
        XCTAssertEqual(t, .identity)
    }

    func testWriterTransformSquareIsIdentity() {
        // 3024×3024 — iPhone 17 front 1×1 native sensor or .ratio1x1
        // reshape. Identity is the conservative default for square.
        let t = RecordingSession.writerTransform(forBufferWidth: 3024, height: 3024)
        XCTAssertEqual(t, .identity)
    }

    // MARK: - PreviewView.previewRotationAngle

    func testPreviewAngleLandscapeIs90() {
        // 4032×3024 → preview connection rotates 90° for portrait display.
        XCTAssertEqual(
            PreviewView.previewRotationAngle(forBufferWidth: 4032, height: 3024),
            90
        )
    }

    func testPreviewAnglePortraitIs0() {
        // 2160×3840 → buffer arrives portrait, no preview rotation.
        XCTAssertEqual(
            PreviewView.previewRotationAngle(forBufferWidth: 2160, height: 3840),
            0
        )
    }

    func testPreviewAngleSquareIs90() {
        // Square buffers default to 90° (legacy landscape-sensor behaviour).
        // The preview-layer's videoGravity handles the actual fit; rotation
        // for square is a no-op visually but the default keeps the legacy
        // path the same on devices that never reshape.
        XCTAssertEqual(
            PreviewView.previewRotationAngle(forBufferWidth: 3024, height: 3024),
            90
        )
    }

    func testPreviewAngleZeroIs90() {
        // No device / KVO not yet fired → fall back to legacy 90° default.
        XCTAssertEqual(
            PreviewView.previewRotationAngle(forBufferWidth: 0, height: 0),
            90
        )
    }

    // MARK: - RecordingSelfTest.playbackDimensions

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
        // 4032×3024 + -π/2 [0,-1,1,0] → plays 3024×4032 (portrait, correct).
        let rotation: [Double] = [0, -1, 1, 0]
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
        let bugTransform: [Double] = [0, -1, 1, 0]
        let (w, h) = RecordingSelfTest.playbackDimensions(
            encodedWidth: 2160, encodedHeight: 3840, transform: bugTransform
        )
        XCTAssertEqual(w, 3840, "bug regression: dogfood-pass-10 played 3840 wide")
        XCTAssertEqual(h, 2160, "bug regression: dogfood-pass-10 played 2160 tall")
        XCTAssertFalse(h > w, "the new portrait-playback assertion would fail this case (correctly)")
    }

    // MARK: - Integration: end-to-end orientation predictions

    /// For each aspect/buffer-shape the user can pick, predict (a) what
    /// transform `writerTransform` chooses and (b) what the resulting file
    /// would play as via `playbackDimensions`. Acceptance criteria for a
    /// known-good build: every row's playback orientation is portrait
    /// (or square for `.ratio1x1`).
    func testEndToEndOrientationPredictions() {
        // (label, bufferW, bufferH, expectedPlaybackW, expectedPlaybackH)
        let cases: [(String, Int, Int, Int, Int)] = [
            (".ratio9x16 (iOS 26)", 2160, 3840, 2160, 3840),
            (".ratio4x3", 4032, 3024, 3024, 4032),
            (".ratio16x9", 4032, 2268, 2268, 4032),
            (".ratio1x1 (iPhone 17 sensor)", 3024, 3024, 3024, 3024),
            (".openGate iPhone17 1×1", 3024, 3024, 3024, 3024),
            (".openGate older 4:3", 4032, 3024, 3024, 4032)
        ]
        for c in cases {
            let (label, bufW, bufH, expW, expH) = c
            let xform = RecordingSession.writerTransform(forBufferWidth: bufW, height: bufH)
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
}

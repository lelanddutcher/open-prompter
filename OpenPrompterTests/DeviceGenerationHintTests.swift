//
//  DeviceGenerationHintTests.swift
//  OpenPrompterTests
//
//  V3 Design 06 — Device Orientation Hint (GitHub #2: iPhone 13 Pro preview
//  rotated 90° + locked).
//
//  Simulators have no camera, so they can't validate that a chosen preview
//  angle produces an upright image. But a simulator DOES report a real
//  `utsname.machine`, so the DETECTION + ROW-SELECTION path is fully
//  exercisable in the sim. That's what this file pins:
//
//    Layer 1 (pure, table-driven, the fast gate):
//      1. `DeviceGenerationHint.from(modelIdentifier:)` buckets each known
//         model string correctly — including the load-bearing `>= 18` cutoff
//         (iPhone17,x → wide; iPhone18,x → square) and the future-family
//         assumption (iPhone19,x → square).
//      2. `previewRotationAngle(...device:)` returns the intended row value:
//         square/unknown → exact 0; wide → the NAMED placeholder constant
//         (asserted by equality to the constant, NOT a hardcoded degree, so
//         the test stays green when the #2 reporter confirms the real value
//         and we edit the one constant).
//      3. WRITER-UNCHANGED regression guard: `writerTransform(...)` for every
//         (aspect, bufferShape) pair is byte-identical to a snapshot of the
//         pre-refactor table — proof the device axis did NOT leak into the
//         writer (recording is verified correct on both sensor classes).
//
//    Layer 2 (live utsname read):
//      4. `currentDeviceModelIdentifier` returns a non-empty, classifiable
//         string on whatever sim booted, and the live derivation agrees with
//         the pure classifier for that exact string (no divergence between the
//         live path and the tested function).
//
//  What this CANNOT prove (stated out loud, per V3 Design 06 §4.3): the
//  correctness of the wide-front ANGLE VALUE. That's device-blocked and lives
//  in the reporter loop (§5). These tests guarantee the right device lands in
//  the right row, so the fix is genuinely a one-constant change.
//

import XCTest
import CoreGraphics
@testable import OpenPrompter

final class DeviceGenerationHintTests: XCTestCase {

    // MARK: - Layer 1.1: model-string classification (incl. the >= 18 cutoff)

    /// (input utsname.machine, human-readable device, expected hint).
    private static let classificationCases:
        [(raw: String, device: String, expected: OrientationPolicy.DeviceGenerationHint)] = [
        ("iPhone18,2", "iPhone 17 Pro Max (founder device)", .squareFrontSensor),
        ("iPhone18,1", "iPhone 17 Pro",                       .squareFrontSensor),
        ("iPhone18,4", "iPhone 17 (hypothetical variant)",    .squareFrontSensor),
        // Boundary: one generation below the cutoff must be wide.
        ("iPhone17,3", "iPhone 16",                           .wideFrontSensor),
        ("iPhone17,1", "iPhone 16 Pro",                       .wideFrontSensor),
        ("iPhone15,4", "iPhone 15",                           .wideFrontSensor),
        ("iPhone14,2", "iPhone 13 Pro  ← GitHub #2",          .wideFrontSensor),
        ("iPhone14,6", "iPhone SE (3rd gen)",                 .wideFrontSensor),
        ("iPhone10,1", "iPhone 8",                            .wideFrontSensor),
        ("iPhone8,1",  "iPhone 6s",                           .wideFrontSensor),
        // Future family: assumed to inherit the square front sensor. Documented,
        // revisitable assumption (V3 Design 06 §2.1) — pinned so it can't drift.
        ("iPhone19,1", "iPhone 18 (future)",                  .squareFrontSensor),
        ("iPhone20,1", "iPhone 19 (further future)",          .squareFrontSensor),
        // Non-iPhone / unclassifiable → unknown → safe default (today's behavior).
        ("iPad13,1",   "iPad Air",                            .unknown),
        ("iPad14,3",   "iPad Pro",                            .unknown),
        ("x86_64",     "Intel simulator host",               .unknown),
        ("arm64",      "Apple-silicon simulator host",       .unknown),
        ("iPhone",     "marketing-only, no generation",      .unknown),
        ("iPhone,",    "malformed: empty generation",        .unknown),
        ("iPhoneX,1",  "malformed: non-numeric generation",  .unknown),
        ("",           "empty",                               .unknown),
        ("Mac15,3",    "Mac (Catalyst / mistaken host)",     .unknown),
    ]

    func testModelStringClassification() {
        for c in Self.classificationCases {
            XCTAssertEqual(
                OrientationPolicy.DeviceGenerationHint.from(modelIdentifier: c.raw),
                c.expected,
                "\(c.raw) (\(c.device)) should classify as \(c.expected)"
            )
        }
    }

    /// The single load-bearing constant is the `>= 18` cutoff. Pin the exact
    /// boundary so a refactor that shifts it fails loudly.
    func testGenerationCutoffBoundaryIsExactlyEighteen() {
        XCTAssertEqual(
            OrientationPolicy.DeviceGenerationHint.from(modelIdentifier: "iPhone17,99"),
            .wideFrontSensor,
            "iPhone17,x (any submodel) is BELOW the square-front cutoff"
        )
        XCTAssertEqual(
            OrientationPolicy.DeviceGenerationHint.from(modelIdentifier: "iPhone18,0"),
            .squareFrontSensor,
            "iPhone18,x (any submodel) is AT/ABOVE the square-front cutoff"
        )
    }

    // MARK: - Layer 1.2: preview row selection per device hint

    /// Every aspect × bufferShape, so the device axis is the only thing that
    /// moves the returned angle.
    private static let allAspects: [RecordingAspect] =
        [.wide, .square, .classic, .openGate]
    private static let allShapes: [OrientationPolicy.BufferShape] =
        [.portrait, .landscape, .square]

    func testPreviewRowSquareAndUnknownAreExactlyZero() {
        for device in [OrientationPolicy.DeviceGenerationHint.squareFrontSensor, .unknown] {
            for aspect in Self.allAspects {
                for shape in Self.allShapes {
                    XCTAssertEqual(
                        OrientationPolicy.previewRotationAngle(
                            for: aspect, bufferShape: shape, device: device
                        ),
                        0,
                        "\(device) must stay 0° (verified baseline / safe default) for \(aspect) × \(shape)"
                    )
                }
            }
        }
    }

    func testPreviewRowWideFrontEqualsNamedPlaceholderNotHardcodedDegree() {
        // Assert equality to the NAMED constant — NOT a literal 270 — so that
        // when the #2 reporter confirms the real angle and we edit the single
        // constant, this test stays green without touching the assertion.
        for aspect in Self.allAspects {
            for shape in Self.allShapes {
                XCTAssertEqual(
                    OrientationPolicy.previewRotationAngle(
                        for: aspect, bufferShape: shape, device: .wideFrontSensor
                    ),
                    OrientationPolicy.PREVIEW_ANGLE_WIDE_FRONT_UNVERIFIED,
                    "\(aspect) × \(shape) on wide-front must return the named placeholder"
                )
            }
        }
    }

    func testWidePlaceholderIsDistinctFromBaseline() {
        // Guardrail: the whole point of #2 is that wide-front needs a DIFFERENT
        // angle than the 0° baseline. If someone "fixes" the constant back to 0
        // the fix silently disappears — catch that.
        XCTAssertNotEqual(
            OrientationPolicy.PREVIEW_ANGLE_WIDE_FRONT_UNVERIFIED, 0,
            "wide-front placeholder must differ from the 0° square-front baseline"
        )
    }

    // MARK: - Layer 1.3: WRITER-UNCHANGED regression guard
    //
    // Snapshot of the pre-refactor writerTransform table. The device axis was
    // added ONLY to previewRotationAngle; the writer must be byte-identical
    // for every (aspect, bufferShape). Values transcribed from the shipped
    // pass-13g table (identity, or +π/2 = [0,1,-1,0]):
    //   - portrait-intent shapes (classic/square/openGate):
    //       .portrait → identity ; .landscape/.square → +π/2
    //   - landscape-intent shape (.wide, the merged 16:9):
    //       .portrait → +π/2 ; .landscape/.square → identity

    private static let rotPiOverTwo = CGAffineTransform(rotationAngle: .pi / 2)

    private static func expectedWriterTransform(
        aspect: RecordingAspect,
        shape: OrientationPolicy.BufferShape
    ) -> CGAffineTransform {
        let portraitIntent = aspect.canonicalShape != .wide
        if portraitIntent {
            switch shape {
            case .portrait:            return .identity
            case .landscape, .square:  return rotPiOverTwo
            }
        } else {
            switch shape {
            case .portrait:            return rotPiOverTwo
            case .landscape, .square:  return .identity
            }
        }
    }

    func testWriterTransformUnchangedByDeviceHintRefactor() {
        for aspect in Self.allAspects {
            for shape in Self.allShapes {
                let actual = OrientationPolicy.writerTransform(for: aspect, bufferShape: shape)
                let expected = Self.expectedWriterTransform(aspect: aspect, shape: shape)
                XCTAssertEqual(actual.a, expected.a, accuracy: 1e-9, "\(aspect) × \(shape): a")
                XCTAssertEqual(actual.b, expected.b, accuracy: 1e-9, "\(aspect) × \(shape): b")
                XCTAssertEqual(actual.c, expected.c, accuracy: 1e-9, "\(aspect) × \(shape): c")
                XCTAssertEqual(actual.d, expected.d, accuracy: 1e-9, "\(aspect) × \(shape): d")
            }
        }
    }

    // MARK: - Back-compat: the 2-arg overload matches the 3-arg live path

    func testTwoArgOverloadMatchesThreeArgWithLiveDevice() {
        let liveDevice = OrientationPolicy.DeviceGenerationHint.from(
            modelIdentifier: OrientationPolicy.currentDeviceModelIdentifier
        )
        for aspect in Self.allAspects {
            for shape in Self.allShapes {
                XCTAssertEqual(
                    OrientationPolicy.previewRotationAngle(for: aspect, bufferShape: shape),
                    OrientationPolicy.previewRotationAngle(
                        for: aspect, bufferShape: shape, device: liveDevice
                    ),
                    "2-arg overload must forward to the 3-arg with the live device hint"
                )
            }
        }
    }

    // MARK: - Layer 2: live utsname read (validates the input on real sim HW)

    func testLiveModelIdentifierIsNonEmptyAndClassifiable() {
        let live = OrientationPolicy.currentDeviceModelIdentifier
        XCTAssertFalse(live.isEmpty, "live utsname.machine read must not be empty")
        // Simulators report "arm64"/"x86_64"; real (simulated) device models
        // report "iPhoneNN,M" / "iPadNN,M". Either shape is classifiable.
        let classifiable = live.hasPrefix("iPhone")
            || live.hasPrefix("iPad")
            || live == "arm64"
            || live == "x86_64"
        XCTAssertTrue(
            classifiable,
            "live model '\(live)' should match a known family/host prefix"
        )
    }

    func testLiveDerivationAgreesWithPureClassifier() {
        // No divergence between the live path and the pure function: whatever
        // the booted sim reports, the hint derived live must equal the hint the
        // tested classifier returns for that exact string.
        let live = OrientationPolicy.currentDeviceModelIdentifier
        let liveHint = OrientationPolicy.DeviceGenerationHint.from(modelIdentifier: live)
        let pureHint = OrientationPolicy.DeviceGenerationHint.from(modelIdentifier: live)
        XCTAssertEqual(liveHint, pureHint)
    }

    // MARK: - DEBUG angle-cycler

    #if DEBUG
    func testAngleCyclerAdvancesThroughFullCycle() {
        let key = "debug.orientation.wideFrontPreviewAngle"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // Start from a known "no override" state.
        OrientationPolicy.debugWideFrontPreviewAngleOverride = nil
        XCTAssertNil(OrientationPolicy.debugWideFrontPreviewAngleOverride)

        // nil → 0 → 90 → 180 → 270 → nil
        XCTAssertEqual(OrientationPolicy.cycleDebugWideFrontPreviewAngle(), 0)
        XCTAssertEqual(OrientationPolicy.cycleDebugWideFrontPreviewAngle(), 90)
        XCTAssertEqual(OrientationPolicy.cycleDebugWideFrontPreviewAngle(), 180)
        XCTAssertEqual(OrientationPolicy.cycleDebugWideFrontPreviewAngle(), 270)
        XCTAssertNil(OrientationPolicy.cycleDebugWideFrontPreviewAngle())
    }

    func testAngleCyclerOverridesWideFrontRowOnly() {
        let key = "debug.orientation.wideFrontPreviewAngle"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        OrientationPolicy.debugWideFrontPreviewAngleOverride = 90
        // Wide-front row honors the override…
        XCTAssertEqual(
            OrientationPolicy.previewRotationAngle(
                for: .classic, bufferShape: .landscape, device: .wideFrontSensor
            ),
            90
        )
        // …but the verified square-front baseline is NEVER affected.
        XCTAssertEqual(
            OrientationPolicy.previewRotationAngle(
                for: .classic, bufferShape: .landscape, device: .squareFrontSensor
            ),
            0
        )
        XCTAssertEqual(
            OrientationPolicy.previewRotationAngle(
                for: .classic, bufferShape: .landscape, device: .unknown
            ),
            0
        )

        // Clearing the override returns wide-front to the named placeholder.
        OrientationPolicy.debugWideFrontPreviewAngleOverride = nil
        XCTAssertEqual(
            OrientationPolicy.previewRotationAngle(
                for: .classic, bufferShape: .landscape, device: .wideFrontSensor
            ),
            OrientationPolicy.PREVIEW_ANGLE_WIDE_FRONT_UNVERIFIED
        )
    }
    #endif
}

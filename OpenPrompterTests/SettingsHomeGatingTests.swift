//
//  SettingsHomeGatingTests.swift
//  OpenPrompterTests
//
//  Covers the one piece of pure logic in the Settings overhaul (V3 Sprint
//  item 2): the gate that decides whether `SettingsHomeView` offers the
//  "Camera & recording" drill-down row. The overhaul is otherwise pure view
//  re-composition (no PrefKey changes), so this truth table is the meaningful
//  regression surface — it must stay identical to the flat view's union of
//  the camera-section gate (`labsCameraStyle || style != off`) and the
//  recording-section gate (`labsRecording`).
//

import XCTest
@testable import OpenPrompter

final class SettingsHomeGatingTests: XCTestCase {

    // MARK: - Hidden only when everything is off / default

    func testHiddenWhenAllFlagsOffAndStyleOff() {
        XCTAssertFalse(
            SettingsHomeView.shouldShowCaptureRow(
                labsCameraStyle: false,
                labsRecording: false,
                cameraStyleRaw: "off"
            ),
            "No Labs flag and no active camera style → the drill-down stays hidden."
        )
    }

    // MARK: - Any single trigger surfaces the row

    func testShownWhenCameraStyleLabsOn() {
        XCTAssertTrue(
            SettingsHomeView.shouldShowCaptureRow(
                labsCameraStyle: true,
                labsRecording: false,
                cameraStyleRaw: "off"
            )
        )
    }

    func testShownWhenRecordingLabsOn() {
        XCTAssertTrue(
            SettingsHomeView.shouldShowCaptureRow(
                labsCameraStyle: false,
                labsRecording: true,
                cameraStyleRaw: "off"
            )
        )
    }

    func testShownWhenUserPickedPipStyleEvenWithLabsOff() {
        // A user who enabled PiP via the in-prompter chip must never lose the
        // settings entry, even if a future build flips the Labs flags off.
        XCTAssertTrue(
            SettingsHomeView.shouldShowCaptureRow(
                labsCameraStyle: false,
                labsRecording: false,
                cameraStyleRaw: "pip"
            )
        )
    }

    func testShownForAnyNonOffStyleString() {
        // The gate keys off "not equal to off", not an allow-list — so any
        // future non-off style raw value keeps the row reachable.
        for raw in ["pip", "behind", "somethingNew"] {
            XCTAssertTrue(
                SettingsHomeView.shouldShowCaptureRow(
                    labsCameraStyle: false,
                    labsRecording: false,
                    cameraStyleRaw: raw
                ),
                "style '\(raw)' is non-off → row shown."
            )
        }
    }

    // MARK: - Combinations still surface

    func testShownWhenEverythingOn() {
        XCTAssertTrue(
            SettingsHomeView.shouldShowCaptureRow(
                labsCameraStyle: true,
                labsRecording: true,
                cameraStyleRaw: "pip"
            )
        )
    }
}

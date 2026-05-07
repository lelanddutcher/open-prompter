//
//  HotfixDefaultsTests.swift
//  OpenPrompterTests
//
//  2.0.1 hotfix sanity tests. Validates that the three Labs feature
//  flags graduated to ON by default and that `cameraStyle` defaults
//  to `"pip"` so the in-app camera is discoverable without the user
//  having to find Settings → Labs first. These defaults drive whether
//  a fresh-installed user sees the camera/recording chips at all,
//  which is the entire point of the 2.0.1 release.
//
//  These are intentionally brittle: if anyone flips the registration-
//  domain default back to false / "off" in a future change, this test
//  fires immediately. The comment in `Prefs.swift` documents the
//  reasoning; this test enforces it at CI time.
//

import XCTest
@testable import OpenPrompter

final class HotfixDefaultsTests: XCTestCase {

    // MARK: - Labs feature flags (2.0.1: graduated)

    func test_labsCameraStyle_registrationDefault_isTrue() {
        XCTAssertEqual(
            PrefKey.labsCameraStyle.defaultValue as? Bool,
            true,
            "Camera Style is shipped, not Labs. Fresh installs must see the camera chip."
        )
    }

    func test_labsRecording_registrationDefault_isTrue() {
        XCTAssertEqual(
            PrefKey.labsRecording.defaultValue as? Bool,
            true,
            "Recording is shipped, not Labs. Fresh installs must see the REC chip."
        )
    }

    func test_labsBluetoothRemote_registrationDefault_isTrue() {
        XCTAssertEqual(
            PrefKey.labsBluetoothRemote.defaultValue as? Bool,
            true,
            "Bluetooth Remote is shipped. Fresh installs must work with paired remotes immediately."
        )
    }

    // MARK: - Camera style (2.0.1: discoverable on first open)

    func test_cameraStyle_registrationDefault_isPip() {
        XCTAssertEqual(
            PrefKey.cameraStyle.defaultValue as? String,
            "pip",
            "Default camera mode for fresh installs is PiP — the founder's directive in the 2.0.1 hotfix is that the camera is on by default so the feature is obvious without diving into Settings."
        )
    }

    // MARK: - Permission usage strings

    /// Every permission that `PermissionPrimer.requestAllIfNeeded()`
    /// asks for must have a matching usage string in the app's
    /// Info.plist or iOS will hard-crash the prompt. This test reads
    /// the bundle's Info.plist and verifies all three are present and
    /// non-empty. Catches any future Info.plist regression at unit-
    /// test time instead of at user-facing crash time.
    func test_infoPlist_hasAllPermissionUsageStrings() {
        let bundle = Bundle(for: type(of: self))
        // The test bundle's Info.plist is its own — we want the
        // host app's. Walk up to the .app bundle.
        let appBundle: Bundle = {
            var url = bundle.bundleURL
            while url.pathExtension != "app" && url.path != "/" {
                url.deleteLastPathComponent()
            }
            return Bundle(url: url) ?? bundle
        }()

        for key in [
            "NSCameraUsageDescription",
            "NSMicrophoneUsageDescription",
            "NSSpeechRecognitionUsageDescription",
        ] {
            let value = appBundle.object(forInfoDictionaryKey: key) as? String
            XCTAssertNotNil(value, "Missing \(key) in Info.plist — system permission prompt will crash")
            XCTAssertFalse((value ?? "").isEmpty, "\(key) is empty — Apple rejects empty usage strings")
        }
    }

    // MARK: - Note on PermissionPrimer
    //
    // No live test of `PermissionPrimer.requestAllIfNeeded()` here.
    // SFSpeechRecognizer.requestAuthorization hangs on iOS Simulator
    // when the host has no Apple ID logged in (the framework can't
    // reach speech-recognition registration), and we don't want a
    // CI timeout. The primer's logic is intentionally trivial — three
    // status-checks gating three system requests — so the value of an
    // execution-path test is low. The Info.plist test above catches
    // the only failure mode that matters: a missing usage string
    // would crash the prompt at runtime, regardless of test coverage.
}

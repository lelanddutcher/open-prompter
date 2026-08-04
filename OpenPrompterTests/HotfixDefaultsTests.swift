//
//  HotfixDefaultsTests.swift
//  OpenPrompterTests
//
//  Registration-domain default sanity tests. Validates that the three
//  Labs feature flags graduated to ON by default (so a fresh-installed
//  user sees the camera/recording/remote chips) AND that `cameraStyle`
//  defaults to `"off"` — the camera is OPT-IN.
//
//  The camera default was `"pip"` in the 2.0.1 hotfix, but a `.pip`
//  default auto-mounts a PiP tile on first launch whose preview layer
//  paints black before any frames flow (the first-run "black box" bug).
//  The fix flips the default to `"off"` and surfaces an opt-in "enable
//  camera" coach-mark instead. The Labs flags stay ON so the chip is
//  still visible for the user to enable the camera whenever they want.
//
//  These are intentionally brittle: if anyone flips the camera default
//  back to `"pip"`, or drops a Labs flag, this test fires immediately.
//  The comments in `Prefs.swift` / `CameraStyle.swift` document the
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

    // MARK: - Camera style (opt-in: no black box on first launch)

    /// The camera is OPT-IN. A `"pip"` registration default auto-mounts a
    /// PiP tile on first launch whose `AVCaptureVideoPreviewLayer` paints
    /// black before frames flow — the first-run "black box" bug. The default
    /// must be `"off"`; users enable the camera via the coach-mark "enable
    /// camera" button (which calls `CameraStore.setStyle(.pip)`) or the chip.
    func test_cameraStyle_registrationDefault_isOff() {
        XCTAssertEqual(
            PrefKey.cameraStyle.defaultValue as? String,
            "off",
            "Default camera mode for fresh installs must be OFF — a .pip default auto-mounts a black PiP tile on first launch. The camera is opt-in via the coach-mark. Do NOT flip this back to \"pip\"."
        )
    }

    /// The `Prefs.cameraStyle` accessor must also resolve to `"off"` on a
    /// fresh registration (no persisted value), matching the registration
    /// default. This guards the read path a `CameraStore.init` takes.
    func test_cameraStyle_freshRegistration_resolvesToOff() {
        let suiteName = "HotfixDefaultsTests.cameraStyle.\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suiteName) else {
            XCTFail("could not create isolated UserDefaults suite")
            return
        }
        defer { store.removePersistentDomain(forName: suiteName) }
        // Register the same registration-domain defaults into the isolated
        // suite, then read the camera style out. No user has written a value,
        // so the registration default is what surfaces.
        store.register(defaults: [
            PrefKey.cameraStyle.rawValue: PrefKey.cameraStyle.defaultValue
        ])
        XCTAssertEqual(
            store.string(forKey: PrefKey.cameraStyle.rawValue),
            "off",
            "A fresh registration with no persisted value must resolve camera style to off."
        )
    }

    // MARK: - Recording aspect (3.1: open gate is the shipping default)

    /// 3.1 flipped the fresh-install aspect from `"ratio16x9"` (`.wide`) to
    /// `"openGate"`. 16:9 is a CROP on any front sensor that isn't natively
    /// 16:9, so off the iPhone 17 family it was a surprising first-record
    /// aspect. Open gate carries no `requiresIOS26` constraint — it is
    /// honored on every device and OS we ship to. Brittle on purpose.
    func test_recordingAspect_registrationDefault_isOpenGate() {
        XCTAssertEqual(
            PrefKey.recordingAspect.defaultValue as? String,
            "openGate",
            "Fresh installs must default to open gate (3.1). 16:9 is a crop on non-native sensors."
        )
    }

    /// A fresh registration with no persisted value must resolve to
    /// `"openGate"` — this is the read path `CameraStore` / `OrientationPolicy`
    /// take on first launch.
    func test_recordingAspect_freshRegistration_resolvesToOpenGate() {
        let suiteName = "HotfixDefaultsTests.recordingAspect.\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suiteName) else {
            XCTFail("could not create isolated UserDefaults suite")
            return
        }
        defer { store.removePersistentDomain(forName: suiteName) }
        store.register(defaults: [
            PrefKey.recordingAspect.rawValue: PrefKey.recordingAspect.defaultValue
        ])
        XCTAssertEqual(
            store.string(forKey: PrefKey.recordingAspect.rawValue),
            "openGate",
            "A fresh registration with no persisted value must resolve the aspect to open gate."
        )
    }

    // MARK: - Reading-progress bar (3.1: optional, default ON)

    /// The left-edge reading-progress bar became optional in 3.1. Default ON
    /// preserves the shipped behavior — an existing user who upgrades must
    /// not have the bar silently disappear.
    func test_showReadingProgressBar_registrationDefault_isTrue() {
        XCTAssertEqual(
            PrefKey.showReadingProgressBar.defaultValue as? Bool,
            true,
            "The reading-progress bar must default ON — turning it off by default would silently change the prompter for every upgrading user."
        )
    }

    /// Fresh registration resolves to `true`, matching the registration
    /// default. This is the value `TeleprompterView`'s `@AppStorage` sees
    /// before the user ever visits Settings.
    func test_showReadingProgressBar_freshRegistration_resolvesToTrue() {
        let suiteName = "HotfixDefaultsTests.progressBar.\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suiteName) else {
            XCTFail("could not create isolated UserDefaults suite")
            return
        }
        defer { store.removePersistentDomain(forName: suiteName) }
        store.register(defaults: [
            PrefKey.showReadingProgressBar.rawValue: PrefKey.showReadingProgressBar.defaultValue
        ])
        XCTAssertTrue(
            store.bool(forKey: PrefKey.showReadingProgressBar.rawValue),
            "A fresh registration with no persisted value must show the progress bar."
        )
    }

    /// The `Prefs.showReadingProgressBar` accessor round-trips both ways.
    /// Snapshot/restore the standard-defaults key so the rest of the suite
    /// sees pristine state.
    func test_showReadingProgressBar_roundTrips() {
        let store = UserDefaults.standard
        let key = PrefKey.showReadingProgressBar.rawValue
        let saved = store.object(forKey: key)
        defer {
            if let saved { store.set(saved, forKey: key) } else { store.removeObject(forKey: key) }
        }

        Prefs.showReadingProgressBar = false
        XCTAssertFalse(Prefs.showReadingProgressBar, "Setting false must read back false.")
        XCTAssertFalse(store.bool(forKey: key), "The write must land on the backing key.")

        Prefs.showReadingProgressBar = true
        XCTAssertTrue(Prefs.showReadingProgressBar, "Setting true must read back true.")
        XCTAssertTrue(store.bool(forKey: key), "The write must land on the backing key.")
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

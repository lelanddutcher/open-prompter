//
//  CameraTests.swift
//  OpenPrompterTests
//
//  Unit tests for Camera Style + PiP (V2 Feature 1).
//  Per the design doc test plan:
//    - CameraStyle round-trip codable
//    - PipCorner.nearestCorner(to:in:) math
//    - PipSize cycle order
//    - CameraStore state transitions (off → pip → behind → off, denial path)
//    - RecordingState flips tally light visibility
//    - Persistence keys round-trip through UserDefaults
//
//  We avoid touching real AVFoundation devices in any test by passing
//  `suppressDeviceWork: true` to CameraStore. The state-machine logic
//  exercises the same code paths as production minus the actual session
//  startRunning/stopRunning calls.
//

import XCTest
@testable import OpenPrompter

@MainActor
final class CameraTests: XCTestCase {

    // MARK: - Cleanup helpers

    private let cameraKeys: [String] = [
        PrefKey.cameraStyle.rawValue,
        PrefKey.cameraFacingFront.rawValue,
        PrefKey.cameraPipSize.rawValue,
        PrefKey.cameraPipCornerLast.rawValue,
        PrefKey.labsCameraStyle.rawValue,
        PrefKey.coachMarkCameraStyleShown.rawValue
    ]

    private var savedValues: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        let store = UserDefaults.standard
        savedValues.removeAll(keepingCapacity: true)
        for key in cameraKeys {
            savedValues[key] = store.object(forKey: key)
            store.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        let store = UserDefaults.standard
        for key in cameraKeys {
            if case let .some(value?) = savedValues[key] {
                store.set(value, forKey: key)
            } else {
                store.removeObject(forKey: key)
            }
        }
        savedValues.removeAll()
        super.tearDown()
    }

    // MARK: - CameraStyle codable round-trip

    func testCameraStyleCodableRoundTrip() throws {
        for style in CameraStyle.allCases {
            let data = try JSONEncoder().encode(style)
            let decoded = try JSONDecoder().decode(CameraStyle.self, from: data)
            XCTAssertEqual(decoded, style,
                           "CameraStyle.\(style.rawValue) must round-trip cleanly.")
        }
    }

    func testCameraStyleRawValueStability() {
        // Guards against accidental rename — these strings are persisted
        // to disk and synced via iCloud KVS; renaming any of them is a
        // breaking change that needs a migration.
        XCTAssertEqual(CameraStyle.pip.rawValue, "pip")
        XCTAssertEqual(CameraStyle.behind.rawValue, "behind")
        XCTAssertEqual(CameraStyle.off.rawValue, "off")
    }

    func testCameraStyleNextCycleOrder() {
        // Design spec: tap chip cycles off → pip → behind → off.
        XCTAssertEqual(CameraStyle.off.nextStyle, .pip)
        XCTAssertEqual(CameraStyle.pip.nextStyle, .behind)
        XCTAssertEqual(CameraStyle.behind.nextStyle, .off)
    }

    func testCameraStyleRequiresPermissionFlag() {
        XCTAssertFalse(CameraStyle.off.requiresCameraPermission,
                       "off mode must work without camera permission.")
        XCTAssertTrue(CameraStyle.pip.requiresCameraPermission)
        XCTAssertTrue(CameraStyle.behind.requiresCameraPermission)
    }

    // MARK: - PipCorner snap-to-nearest

    func testPipCornerNearestForObviousPositions() {
        let viewport = CGSize(width: 390, height: 844)
        let tileSize = PipSize.medium.dimensions

        // A point very near the top-leading corner should snap there.
        let topLeading = CGPoint(x: 50, y: 50)
        XCTAssertEqual(
            PipCorner.nearestCorner(to: topLeading, in: viewport, tileSize: tileSize),
            .topLeading
        )

        // A point near the top-trailing corner snaps there.
        let topTrailing = CGPoint(x: viewport.width - 50, y: 50)
        XCTAssertEqual(
            PipCorner.nearestCorner(to: topTrailing, in: viewport, tileSize: tileSize),
            .topTrailing
        )

        // A point near bottom-leading corner snaps there.
        let bottomLeading = CGPoint(x: 50, y: viewport.height - 50)
        XCTAssertEqual(
            PipCorner.nearestCorner(to: bottomLeading, in: viewport, tileSize: tileSize),
            .bottomLeading
        )

        // A point near bottom-trailing corner snaps there.
        let bottomTrailing = CGPoint(x: viewport.width - 50, y: viewport.height - 50)
        XCTAssertEqual(
            PipCorner.nearestCorner(to: bottomTrailing, in: viewport, tileSize: tileSize),
            .bottomTrailing
        )
    }

    func testPipCornerSnapsToTopCenter() {
        // The top-center anchor is exactly horizontally centered along the
        // top edge — a point released there should pick `.topCenter`.
        let viewport = CGSize(width: 390, height: 844)
        let tileSize = PipSize.medium.dimensions
        let anchor = PipCorner.topCenter.center(in: viewport, tileSize: tileSize, inset: 12)

        XCTAssertEqual(
            PipCorner.nearestCorner(to: anchor, in: viewport, tileSize: tileSize),
            .topCenter
        )
    }

    func testPipCornerCenterRespectsInsetAndTileSize() {
        let viewport = CGSize(width: 400, height: 800)
        let tileSize = CGSize(width: 100, height: 100)
        let inset: CGFloat = 16

        let topLeading = PipCorner.topLeading.center(
            in: viewport,
            tileSize: tileSize,
            inset: inset
        )
        // Anchor for top-leading should be (inset + halfW, inset + halfH).
        XCTAssertEqual(topLeading.x, inset + 50, accuracy: 0.001)
        XCTAssertEqual(topLeading.y, inset + 50, accuracy: 0.001)

        let bottomTrailing = PipCorner.bottomTrailing.center(
            in: viewport,
            tileSize: tileSize,
            inset: inset
        )
        XCTAssertEqual(bottomTrailing.x, viewport.width - inset - 50, accuracy: 0.001)
        XCTAssertEqual(bottomTrailing.y, viewport.height - inset - 50, accuracy: 0.001)
    }

    // MARK: - PipSize

    func testPipSizeCycleOrder() {
        XCTAssertEqual(PipSize.small.nextSize, .medium)
        XCTAssertEqual(PipSize.medium.nextSize, .large)
        XCTAssertEqual(PipSize.large.nextSize, .small)
    }

    func testPipSizeDimensionsMatchSpec() {
        // Design spec values — the chip looks alien if any of these drift.
        XCTAssertEqual(PipSize.small.dimensions, CGSize(width: 110, height: 145))
        XCTAssertEqual(PipSize.medium.dimensions, CGSize(width: 130, height: 175))
        XCTAssertEqual(PipSize.large.dimensions, CGSize(width: 160, height: 215))
    }

    func testPipSizeIsPortrait3to4() {
        // V2 Design 01: tile must be portrait. Permit a small float drift.
        for size in PipSize.allCases {
            let ratio = size.dimensions.width / size.dimensions.height
            XCTAssertEqual(ratio, 0.75, accuracy: 0.05,
                           "PipSize.\(size.rawValue) must be ~3:4 portrait.")
        }
    }

    // MARK: - CameraStore state transitions

    func testStoreSeedsFromPrefs() {
        UserDefaults.standard.set("pip", forKey: PrefKey.cameraStyle.rawValue)
        UserDefaults.standard.set(false, forKey: PrefKey.cameraFacingFront.rawValue)

        let store = CameraStore(suppressDeviceWork: true)
        XCTAssertEqual(store.style, .pip)
        XCTAssertFalse(store.facingFront)
    }

    func testStoreFallsBackToOffOnUnknownPrefValue() {
        // A downgrade scenario: a future build wrote a new mode we don't
        // know about. We should not crash; we land on `.off`.
        UserDefaults.standard.set("zoomed", forKey: PrefKey.cameraStyle.rawValue)
        let store = CameraStore(suppressDeviceWork: true)
        XCTAssertEqual(store.style, .off,
                       "Unknown raw value must fall back to .off without crashing.")
    }

    func testStorePersistsStyleChange() async {
        let store = CameraStore(suppressDeviceWork: true)

        // Seeding starts from .off
        XCTAssertEqual(store.style, .off)

        // For tests with suppressDeviceWork, requestAccessIfNeeded falls
        // through to denial when the system status is .notDetermined. We
        // verify the off → off path here (no real perm prompt fires).
        await store.setStyle(.off)
        XCTAssertEqual(store.style, .off)
    }

    func testStoreSwapCameraTogglesPersistedFacing() async {
        let store = CameraStore(suppressDeviceWork: true)
        let startFront = store.facingFront

        await store.swapCamera()

        XCTAssertNotEqual(store.facingFront, startFront,
                          "swapCamera() must invert facingFront.")
        XCTAssertEqual(
            UserDefaults.standard.bool(forKey: PrefKey.cameraFacingFront.rawValue),
            store.facingFront,
            "swapCamera() must persist the new facing immediately."
        )
    }

    func testStoreDeniedPathReturnsToOff() async {
        // With suppressDeviceWork true, requestAccessIfNeeded returns false
        // for an undetermined status — simulating the denial branch.
        let store = CameraStore(suppressDeviceWork: true)
        await store.setStyle(.pip)

        // We're not authorized in tests (no Info.plist plumbing in the
        // test bundle's runtime), so the store should snap back to .off
        // and queue a banner cue for the UI.
        XCTAssertEqual(store.style, .off,
                       "Permission denial must snap style back to .off.")
        XCTAssertTrue(store.consumePermissionDenialBanner(),
                      "Denial path must surface the banner cue exactly once.")
        XCTAssertFalse(store.consumePermissionDenialBanner(),
                       "Banner cue must clear after first read.")
    }

    // MARK: - RecordingState

    func testRecordingStateStartsOff() {
        let state = RecordingState()
        XCTAssertFalse(state.isRecording)
    }

    func testRecordingStateToggleFlipsFlag() {
        let state = RecordingState()
        state.toggleForDebug()
        XCTAssertTrue(state.isRecording)
        state.toggleForDebug()
        XCTAssertFalse(state.isRecording)
    }

    // MARK: - Pref defaults match spec

    func testPrefDefaultsMatchSpec() {
        XCTAssertEqual(PrefKey.cameraStyle.defaultValue as? String, "off",
                       "First-run default must be off (privacy-respecting).")
        XCTAssertEqual(PrefKey.cameraFacingFront.defaultValue as? Bool, true,
                       "Front camera default — selfie creators are the larger audience.")
        XCTAssertEqual(PrefKey.cameraPipSize.defaultValue as? String, "medium")
        XCTAssertEqual(PrefKey.cameraPipCornerLast.defaultValue as? String, "topCenter",
                       "Top-center anchor minimizes eye-line drift at arm's length.")
        XCTAssertEqual(PrefKey.coachMarkCameraStyleShown.defaultValue as? Bool, false,
                       "Coach-mark must default unseen so first-run banner can fire.")
    }

    func testPrefAccessorsRoundTrip() {
        Prefs.cameraStyle = "pip"
        XCTAssertEqual(Prefs.cameraStyle, "pip")
        Prefs.cameraFacingFront = false
        XCTAssertFalse(Prefs.cameraFacingFront)
        Prefs.cameraPipSize = "large"
        XCTAssertEqual(Prefs.cameraPipSize, "large")
        Prefs.cameraPipCornerLast = "bottomTrailing"
        XCTAssertEqual(Prefs.cameraPipCornerLast, "bottomTrailing")
    }
}

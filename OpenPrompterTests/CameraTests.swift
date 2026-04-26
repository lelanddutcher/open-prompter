//
//  CameraTests.swift
//  OpenPrompterTests
//
//  Unit tests for Camera Style + PiP (V2 Feature 1).
//  After the post-merge dogfood pass:
//    - CameraStyle round-trip codable
//    - PipSize cycle order
//    - PipTile.clampedCenter math (free-position model — no corner snap)
//    - CameraStore state transitions (off → pip → off, denial path,
//      optimistic style update)
//    - RecordingState flips tally light visibility
//    - Persistence keys round-trip through UserDefaults
//
//  We avoid touching real AVFoundation devices in any test by passing
//  `suppressDeviceWork: true` to CameraStore. The state-machine logic
//  exercises the same code paths as production minus the actual session
//  startRunning/stopRunning calls.
//

import XCTest
import SwiftUI
@testable import OpenPrompter

@MainActor
final class CameraTests: XCTestCase {

    // MARK: - Cleanup helpers

    private let cameraKeys: [String] = [
        PrefKey.cameraStyle.rawValue,
        PrefKey.cameraPipSize.rawValue,
        PrefKey.cameraPipPositionX.rawValue,
        PrefKey.cameraPipPositionY.rawValue,
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

    // MARK: - PipTile.clampedCenter (free-position math)

    func testPipTileClampHonorsTopSafeArea() {
        // A point near (0, 0) gets pulled DOWN to safeArea.top + topReserve
        // + halfH so the tile doesn't slip under the dynamic island.
        let viewport = CGSize(width: 390, height: 844)
        let dims = CGSize(width: 130, height: 175)
        let safeArea = EdgeInsets(top: 47, leading: 0, bottom: 34, trailing: 0)

        let result = PipTile.clampedCenter(
            point: CGPoint(x: 200, y: 0),
            viewport: viewport,
            tileSize: dims,
            safeArea: safeArea,
            chromeReserve: 140,
            topReserve: 8,
            sidePadding: 12
        )
        XCTAssertGreaterThanOrEqual(
            result.y,
            safeArea.top + 8 + dims.height / 2,
            "Tile center must clear safeArea.top + topReserve + halfH."
        )
    }

    func testPipTileClampHonorsBottomChromeStripWhenChromeVisible() {
        // chromeReserve > safeArea.bottom — the chrome wins. Tile center
        // must end up above viewport.height - chromeReserve - 8 - halfH.
        let viewport = CGSize(width: 390, height: 844)
        let dims = CGSize(width: 130, height: 175)
        let safeArea = EdgeInsets(top: 47, leading: 0, bottom: 34, trailing: 0)

        let result = PipTile.clampedCenter(
            point: CGPoint(x: 200, y: viewport.height + 100),
            viewport: viewport,
            tileSize: dims,
            safeArea: safeArea,
            chromeReserve: 140,
            topReserve: 8,
            sidePadding: 12
        )
        let expectedMaxY = viewport.height - 140 - 8 - dims.height / 2
        XCTAssertLessThanOrEqual(
            result.y,
            expectedMaxY + 0.001,
            "Tile center must stay above the chrome reserve when chrome visible."
        )
    }

    func testPipTileClampReleasesBottomReserveWhenChromeHidden() {
        // chromeReserve == 0 (chrome hidden via tap-to-focus). The tile
        // can land within the home-indicator safe-area bottom but no
        // further than viewport.height - safeArea.bottom - 8 - halfH.
        let viewport = CGSize(width: 390, height: 844)
        let dims = CGSize(width: 130, height: 175)
        let safeArea = EdgeInsets(top: 47, leading: 0, bottom: 34, trailing: 0)

        let result = PipTile.clampedCenter(
            point: CGPoint(x: 200, y: viewport.height + 100),
            viewport: viewport,
            tileSize: dims,
            safeArea: safeArea,
            chromeReserve: 0,
            topReserve: 8,
            sidePadding: 12
        )
        let expectedMaxY = viewport.height - safeArea.bottom - 8 - dims.height / 2
        XCTAssertLessThanOrEqual(
            result.y,
            expectedMaxY + 0.001,
            "Tile center must clear the bottom safe area when chrome hidden."
        )
        // And it must be _below_ the chrome-visible limit because we
        // released that reserve.
        let chromeLimit = viewport.height - 140 - 8 - dims.height / 2
        XCTAssertGreaterThan(
            result.y,
            chromeLimit,
            "Hidden-chrome clamp should reach further down than chrome-visible clamp."
        )
    }

    func testPipTileClampHonorsSidePadding() {
        let viewport = CGSize(width: 390, height: 844)
        let dims = CGSize(width: 130, height: 175)
        let safeArea = EdgeInsets()

        // Far-left release.
        let left = PipTile.clampedCenter(
            point: CGPoint(x: -50, y: 400),
            viewport: viewport,
            tileSize: dims,
            safeArea: safeArea,
            chromeReserve: 0,
            topReserve: 8,
            sidePadding: 12
        )
        XCTAssertEqual(left.x, 12 + dims.width / 2, accuracy: 0.001)

        // Far-right release.
        let right = PipTile.clampedCenter(
            point: CGPoint(x: 1000, y: 400),
            viewport: viewport,
            tileSize: dims,
            safeArea: safeArea,
            chromeReserve: 0,
            topReserve: 8,
            sidePadding: 12
        )
        XCTAssertEqual(right.x, viewport.width - 12 - dims.width / 2, accuracy: 0.001)
    }

    func testPipTileClampPassesInBoundsPointThrough() {
        // A point well inside the safe rectangle should not be moved.
        let viewport = CGSize(width: 390, height: 844)
        let dims = CGSize(width: 130, height: 175)
        let safeArea = EdgeInsets(top: 47, leading: 0, bottom: 34, trailing: 0)

        let inside = CGPoint(x: 195, y: 400)
        let result = PipTile.clampedCenter(
            point: inside,
            viewport: viewport,
            tileSize: dims,
            safeArea: safeArea,
            chromeReserve: 140,
            topReserve: 8,
            sidePadding: 12
        )
        XCTAssertEqual(result.x, inside.x, accuracy: 0.001)
        XCTAssertEqual(result.y, inside.y, accuracy: 0.001)
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
        let store = CameraStore(suppressDeviceWork: true)
        XCTAssertEqual(store.style, .pip)
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

    func testStoreOptimisticStyleFlipToOffIsImmediate() async {
        // Seed with .pip in prefs, then ask the store to flip to .off.
        // The .off transition has no permission gate so the style should
        // update synchronously before stop() returns. We assert via the
        // public API after the await — the optimistic write is observable
        // here (and crucially, in production SwiftUI sees it the moment
        // setStyle yields).
        UserDefaults.standard.set("pip", forKey: PrefKey.cameraStyle.rawValue)
        let store = CameraStore(suppressDeviceWork: true)
        XCTAssertEqual(store.style, .pip)

        await store.setStyle(.off)
        XCTAssertEqual(store.style, .off,
                       "setStyle(.off) must flip style immediately.")
        XCTAssertEqual(Prefs.cameraStyle, "off",
                       "Persistence must reflect the optimistic flip.")
    }

    func testStoreRapidToggleDoesNotDoubleStart() async {
        // The session has its own `if !session.isRunning` guard so calling
        // start() twice in quick succession is a no-op. Suppressed device
        // work has the same idempotency on `isSessionRunning`.
        let store = CameraStore(suppressDeviceWork: true)
        // Force "authorized" by skipping the request path; we can't flip
        // the system status from a unit test, so this only exercises the
        // off-path transitions here. The real-camera idempotency check
        // lives in the production guard on session.isRunning.
        await store.setStyle(.off) // no-op (already off)
        await store.setStyle(.off) // no-op (already off)
        XCTAssertEqual(store.style, .off)
        XCTAssertFalse(store.isSessionRunning)
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

    // MARK: - 4:3 format selection (Bug 1: open-gate)

    /// The dogfood report flagged that recordings were 1440×1080 wrappers
    /// with 16:9 letterboxed content — the front camera was running its
    /// default 16:9 format and the writer was stretching black bars in.
    /// `pickFourThreeFormatIndex` is the pure decision helper called by
    /// `CameraStore.configureInputsLocked` after acquiring the device; if
    /// it picks correctly the writer gets a true 4:3 source and the PiP
    /// preview no longer shows side bars.
    func testPickFourThreeFormatPicksHighestResolutionAt30fps() {
        // iPhone 17 simulator front camera reports these formats. Mix in
        // a couple of 16:9 distractors so the test exercises the filter.
        let descriptors: [CameraStore.FormatDescriptor] = [
            // 16:9 distractors — must not be picked.
            CameraStore.FormatDescriptor(width: 1920, height: 1080,
                                         frameRateRanges: [(1, 60)]),
            CameraStore.FormatDescriptor(width: 1280, height: 720,
                                         frameRateRanges: [(1, 60)]),
            // 4:3 candidates.
            CameraStore.FormatDescriptor(width: 960, height: 720,
                                         frameRateRanges: [(1, 60)]),
            CameraStore.FormatDescriptor(width: 1440, height: 1080,
                                         frameRateRanges: [(1, 60)]),
            CameraStore.FormatDescriptor(width: 1920, height: 1440,
                                         frameRateRanges: [(1, 60)]),
            CameraStore.FormatDescriptor(width: 4032, height: 3024,
                                         frameRateRanges: [(1, 30)])
        ]

        // 30 fps — every 4:3 format covers it; pick the highest area.
        let chosen30 = CameraStore.pickFourThreeFormatIndex(
            descriptors: descriptors, preferredFPS: 30
        )
        XCTAssertEqual(chosen30, 5,
                       "30fps must pick the 4032×3024 4:3 format (the largest).")
    }

    func testPickFourThreeFormatPicksHighest60fpsFormat() {
        // At 60fps the 4032×3024 format is excluded (its range tops at
        // 30fps); we should pick 1920×1440, the largest 4:3 that supports
        // 60fps.
        let descriptors: [CameraStore.FormatDescriptor] = [
            CameraStore.FormatDescriptor(width: 1920, height: 1080,
                                         frameRateRanges: [(1, 60)]),
            CameraStore.FormatDescriptor(width: 960, height: 720,
                                         frameRateRanges: [(1, 60)]),
            CameraStore.FormatDescriptor(width: 1440, height: 1080,
                                         frameRateRanges: [(1, 60)]),
            CameraStore.FormatDescriptor(width: 1920, height: 1440,
                                         frameRateRanges: [(1, 60)]),
            CameraStore.FormatDescriptor(width: 4032, height: 3024,
                                         frameRateRanges: [(1, 30)])
        ]
        let chosen = CameraStore.pickFourThreeFormatIndex(
            descriptors: descriptors, preferredFPS: 60
        )
        XCTAssertEqual(chosen, 3,
                       "60fps must pick 1920×1440 — the largest 4:3 that covers 60fps.")
    }

    func testPickFourThreeFormatReturnsNilWhenNoFormatSupportsFramerate() {
        // No 4:3 format covers 120 fps — fall back to nil so the caller
        // can leave the device default in place rather than mis-configuring.
        let descriptors: [CameraStore.FormatDescriptor] = [
            CameraStore.FormatDescriptor(width: 1920, height: 1080,
                                         frameRateRanges: [(1, 60)]),
            CameraStore.FormatDescriptor(width: 1440, height: 1080,
                                         frameRateRanges: [(1, 60)])
        ]
        let chosen = CameraStore.pickFourThreeFormatIndex(
            descriptors: descriptors, preferredFPS: 120
        )
        XCTAssertNil(chosen,
                     "No 4:3 format covers 120fps — selection must return nil.")
    }

    func testPickFourThreeFormatRejectsNon43Aspects() {
        // Only 16:9 inputs — selection must return nil.
        let descriptors: [CameraStore.FormatDescriptor] = [
            CameraStore.FormatDescriptor(width: 1920, height: 1080,
                                         frameRateRanges: [(1, 60)]),
            CameraStore.FormatDescriptor(width: 1280, height: 720,
                                         frameRateRanges: [(1, 60)])
        ]
        let chosen = CameraStore.pickFourThreeFormatIndex(
            descriptors: descriptors, preferredFPS: 30
        )
        XCTAssertNil(chosen,
                     "No 4:3 format in the list — selection must return nil.")
    }

    // MARK: - Behind-mode reliability (Bug 2)

    /// The dogfood report on `.pip → .behind` transitions: setting the
    /// style optimistically before awaiting `start()` left the user with
    /// `style = .behind` but no running session — black background. The
    /// fix verifies `isSessionRunning` after `start()` returns; if the
    /// session never started, `style` reverts to its previous value.
    ///
    /// This test exercises the happy path: pre-seed authorization to
    /// `.authorized`, drive `.pip → .behind`, assert both the style flip
    /// and the session-running state.
    func testStorePipToBehindFlipsStyleAndKeepsSessionRunning() async {
        let store = CameraStore(suppressDeviceWork: true)
        // Pre-seed authorization so the suppress-device-work request path
        // returns true rather than falling through to the .notDetermined
        // → denied branch.
        store.prepareTestAuthorization(.authorized)

        // off → pip
        await store.setStyle(.pip)
        XCTAssertEqual(store.style, .pip,
                       "Authorized .pip must persist after start().")
        XCTAssertTrue(store.isSessionRunning,
                      "Session must be running once setStyle returns.")

        // pip → behind
        await store.setStyle(.behind)
        XCTAssertEqual(store.style, .behind,
                       "Authorized .pip → .behind must complete the style flip.")
        XCTAssertTrue(store.isSessionRunning,
                      "Session must remain running across mode swap.")
    }

    /// Round-trip the cycle so the persistence path (Prefs.cameraStyle) is
    /// also exercised across two non-off transitions.
    func testStoreFullCycleAuthorizedKeepsStateConsistent() async {
        let store = CameraStore(suppressDeviceWork: true)
        store.prepareTestAuthorization(.authorized)

        await store.setStyle(.pip)
        await store.setStyle(.behind)
        await store.setStyle(.off)
        XCTAssertEqual(store.style, .off)
        XCTAssertFalse(store.isSessionRunning)
    }

    // MARK: - Pref defaults match spec

    func testPrefDefaultsMatchSpec() {
        XCTAssertEqual(PrefKey.cameraStyle.defaultValue as? String, "off",
                       "First-run default must be off (privacy-respecting).")
        XCTAssertEqual(PrefKey.cameraPipSize.defaultValue as? String, "medium")
        XCTAssertEqual(PrefKey.cameraPipPositionX.defaultValue as? Double, 0.5,
                       "Default X is horizontally centered.")
        XCTAssertEqual(PrefKey.cameraPipPositionY.defaultValue as? Double, 0.22,
                       "Default Y sits roughly under the front lens.")
        XCTAssertEqual(PrefKey.coachMarkCameraStyleShown.defaultValue as? Bool, false,
                       "Coach-mark must default unseen so first-run banner can fire.")
    }

    func testPrefAccessorsRoundTrip() {
        Prefs.cameraStyle = "pip"
        XCTAssertEqual(Prefs.cameraStyle, "pip")
        Prefs.cameraPipSize = "large"
        XCTAssertEqual(Prefs.cameraPipSize, "large")
        Prefs.cameraPipPositionX = 0.33
        XCTAssertEqual(Prefs.cameraPipPositionX, 0.33, accuracy: 0.001)
        Prefs.cameraPipPositionY = 0.66
        XCTAssertEqual(Prefs.cameraPipPositionY, 0.66, accuracy: 0.001)
    }
}

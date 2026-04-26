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

import AVFoundation
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

    // MARK: - Open-gate format selection (Bug 1: corrective pass)
    //
    // The previous fix filtered to 4:3 and stopped there. That's wrong on the
    // iPhone 17 family — its front camera has a 1:1 square sensor and forcing
    // a 4:3 readout discards ~25 % of the vertical pixels. The corrective
    // algorithm is tiered:
    //
    //   1. iOS 26 + iPhone 17 family: pick a format that exposes
    //      `supportedDynamicAspectRatios` and switch to 1×1 if available
    //      (full square sensor readout, ~3024×3024 reshaped).
    //   2. Fallback: pick the largest pixel-area format whose framerate
    //      range covers the user's target. The native sensor IS the open
    //      gate when the OS / hardware can't do dynamic aspect.

    /// Largest-pixel-area pick when no candidate declares dynamic-aspect
    /// support. Mixing 16:9, 4:3, and 1:1 candidates — the algorithm should
    /// pick the largest by pixel count regardless of aspect.
    func testOpenGatePicksLargestFormatRegardlessOfAspect() {
        let descriptors: [CameraStore.FormatDescriptor] = [
            // 1280×720 — 16:9.
            CameraStore.FormatDescriptor(width: 1280, height: 720,
                                         frameRateRanges: [(1, 60)]),
            // 1920×1440 — 4:3.
            CameraStore.FormatDescriptor(width: 1920, height: 1440,
                                         frameRateRanges: [(1, 60)]),
            // 1080×1080 — 1:1 (no dynamic-aspect support — should still be
            // a valid candidate, just not preferred over a larger format).
            CameraStore.FormatDescriptor(width: 1080, height: 1080,
                                         frameRateRanges: [(1, 60)]),
            // 4032×3024 — 4:3, the biggest. Should win.
            CameraStore.FormatDescriptor(width: 4032, height: 3024,
                                         frameRateRanges: [(1, 30)])
        ]
        let pick = CameraStore.pickOpenGateFormat(
            descriptors: descriptors, preferredFPS: 30
        )
        XCTAssertEqual(pick?.index, 3,
                       "30fps fallback must pick the largest pixel-area format.")
        XCTAssertNil(pick?.dynamicAspectRaw,
                     "No descriptor declares dynamic-aspect support → no aspect to apply.")
    }

    /// iPhone 17 family pathway: a format that declares `supportedDynamicAspectRatios`
    /// containing 3×4 should be picked, with `.ratio3x4` selected. Portrait
    /// 3:4 matches the PiP tile and the prompter viewport better than any
    /// landscape format and avoids letterboxing / aspect-jump on REC tap.
    func testOpenGatePrefers3x4PortraitWhenDynamicAspectAvailable() {
        if #available(iOS 26.0, *) {
            let descriptors: [CameraStore.FormatDescriptor] = [
                CameraStore.FormatDescriptor(width: 4032, height: 3024,
                                             frameRateRanges: [(1, 30)],
                                             supportsDynamicAspectRatios: false,
                                             dynamicAspectRatios: []),
                CameraStore.FormatDescriptor(
                    width: 3024, height: 4032,
                    frameRateRanges: [(1, 30)],
                    supportsDynamicAspectRatios: true,
                    dynamicAspectRatios: [
                        AVCaptureDevice.AspectRatio.ratio4x3.rawValue,
                        AVCaptureDevice.AspectRatio.ratio3x4.rawValue,
                        AVCaptureDevice.AspectRatio.ratio1x1.rawValue,
                        AVCaptureDevice.AspectRatio.ratio16x9.rawValue
                    ]
                )
            ]
            let pick = CameraStore.pickOpenGateFormat(
                descriptors: descriptors, preferredFPS: 30
            )
            XCTAssertEqual(pick?.index, 1,
                           "Dynamic-aspect format must win over a larger plain format.")
            XCTAssertEqual(pick?.dynamicAspectRaw,
                           AVCaptureDevice.AspectRatio.ratio3x4.rawValue,
                           "3×4 portrait aspect must be selected first when declared.")
        }
    }

    /// Aspect-preference fallback: 1×1 wins when 3×4 isn't declared. Maps to
    /// the original "full square readout" goal — keeps the iPhone 17 forward
    /// path lit up if a future iOS adds 1×1 to the front camera's supported
    /// aspect set.
    func testOpenGateFallsBackTo1x1When3x4Unavailable() {
        if #available(iOS 26.0, *) {
            let descriptors: [CameraStore.FormatDescriptor] = [
                CameraStore.FormatDescriptor(
                    width: 4032, height: 4032,
                    frameRateRanges: [(1, 30)],
                    supportsDynamicAspectRatios: true,
                    dynamicAspectRatios: [
                        AVCaptureDevice.AspectRatio.ratio4x3.rawValue,
                        AVCaptureDevice.AspectRatio.ratio1x1.rawValue,
                        AVCaptureDevice.AspectRatio.ratio16x9.rawValue
                    ]
                )
            ]
            let pick = CameraStore.pickOpenGateFormat(
                descriptors: descriptors, preferredFPS: 30
            )
            XCTAssertEqual(pick?.dynamicAspectRaw,
                           AVCaptureDevice.AspectRatio.ratio1x1.rawValue,
                           "Algorithm must pick 1×1 when 3×4 isn't declared.")
        }
    }

    /// Aspect-preference fallback: 4×3 wins when neither 3×4 nor 1×1 are
    /// declared. Last resort before falling through to the algorithm's
    /// "first declared" tiebreaker.
    func testOpenGateFallsBackTo4x3WhenSquareAndPortraitUnavailable() {
        if #available(iOS 26.0, *) {
            let descriptors: [CameraStore.FormatDescriptor] = [
                CameraStore.FormatDescriptor(
                    width: 4032, height: 3024,
                    frameRateRanges: [(1, 30)],
                    supportsDynamicAspectRatios: true,
                    dynamicAspectRatios: [
                        AVCaptureDevice.AspectRatio.ratio4x3.rawValue,
                        AVCaptureDevice.AspectRatio.ratio16x9.rawValue
                    ]
                )
            ]
            let pick = CameraStore.pickOpenGateFormat(
                descriptors: descriptors, preferredFPS: 30
            )
            XCTAssertEqual(pick?.dynamicAspectRaw,
                           AVCaptureDevice.AspectRatio.ratio4x3.rawValue,
                           "Algorithm must pick 4×3 when 3×4 and 1×1 aren't declared.")
        }
    }

    /// Older OS / older hardware: no descriptor has dynamic-aspect support.
    /// The algorithm falls through to the largest pixel-area candidate and
    /// returns no aspect override.
    func testOpenGateFallsBackWhenNoDynamicAspect() {
        let descriptors: [CameraStore.FormatDescriptor] = [
            // 16:9 distractor.
            CameraStore.FormatDescriptor(width: 1920, height: 1080,
                                         frameRateRanges: [(1, 60)],
                                         supportsDynamicAspectRatios: false,
                                         dynamicAspectRatios: []),
            // 4:3 mid.
            CameraStore.FormatDescriptor(width: 1440, height: 1080,
                                         frameRateRanges: [(1, 60)],
                                         supportsDynamicAspectRatios: false,
                                         dynamicAspectRatios: []),
            // 4:3 large — the open gate on a non-iPhone-17 sensor.
            CameraStore.FormatDescriptor(width: 1920, height: 1440,
                                         frameRateRanges: [(1, 60)],
                                         supportsDynamicAspectRatios: false,
                                         dynamicAspectRatios: [])
        ]
        let pick = CameraStore.pickOpenGateFormat(
            descriptors: descriptors, preferredFPS: 30
        )
        XCTAssertEqual(pick?.index, 2,
                       "Fallback path must pick the largest pixel-area candidate.")
        XCTAssertNil(pick?.dynamicAspectRaw,
                     "No dynamic-aspect support → no aspect override applied.")
    }

    /// Framerate filtering still wins. A high-resolution format that maxes
    /// out at 30 fps must NOT be picked when the user wants 60 fps; the
    /// algorithm falls through to the largest format that DOES cover 60.
    func testOpenGateRespectsFramerateRange() {
        let descriptors: [CameraStore.FormatDescriptor] = [
            // 4032×3024 caps at 30fps — must not be picked when fps == 60.
            CameraStore.FormatDescriptor(width: 4032, height: 3024,
                                         frameRateRanges: [(1, 30)]),
            // 1920×1440 covers 60fps — should be the pick at 60fps.
            CameraStore.FormatDescriptor(width: 1920, height: 1440,
                                         frameRateRanges: [(1, 60)]),
            // 1280×720 covers 60fps — smaller, shouldn't win at 60fps.
            CameraStore.FormatDescriptor(width: 1280, height: 720,
                                         frameRateRanges: [(1, 60)])
        ]
        let pick60 = CameraStore.pickOpenGateFormat(
            descriptors: descriptors, preferredFPS: 60
        )
        XCTAssertEqual(pick60?.index, 1,
                       "60fps must pick the 1920×1440 format (largest that covers 60fps).")

        // At 30fps the 4032×3024 format wins again.
        let pick30 = CameraStore.pickOpenGateFormat(
            descriptors: descriptors, preferredFPS: 30
        )
        XCTAssertEqual(pick30?.index, 0,
                       "30fps must pick the 4032×3024 format (largest covering 30fps).")
    }

    /// Impossible request: every candidate caps below the user's fps. The
    /// algorithm returns nil so the caller leaves the device default
    /// untouched rather than misconfiguring it.
    func testOpenGateReturnsNilWhenNoFormatSupportsFramerate() {
        let descriptors: [CameraStore.FormatDescriptor] = [
            CameraStore.FormatDescriptor(width: 1920, height: 1080,
                                         frameRateRanges: [(1, 60)]),
            CameraStore.FormatDescriptor(width: 1440, height: 1080,
                                         frameRateRanges: [(1, 60)])
        ]
        let pick = CameraStore.pickOpenGateFormat(
            descriptors: descriptors, preferredFPS: 120
        )
        XCTAssertNil(pick,
                     "No format covers 120fps — selection must return nil.")
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

    /// Dogfood-pass-2 Bug 1: the previous fixup reverted `style` to the
    /// previous value if `isSessionRunning` ever read false after `start()`.
    /// On a non-off → non-off transition the session is already running and
    /// the empty begin/commit dance shouldn't second-guess it. Verify a
    /// deliberate sequence behind → pip → behind ALL stick — none of them
    /// should silently revert during the config-only flip.
    func testStoreNonOffToNonOffStyleSticksThroughTransition() async {
        let store = CameraStore(suppressDeviceWork: true)
        store.prepareTestAuthorization(.authorized)

        await store.setStyle(.pip)
        XCTAssertEqual(store.style, .pip)
        XCTAssertTrue(store.isSessionRunning)

        // pip → behind. The previous fixup would mis-revert to .pip on a
        // race with `isSessionRunning`. The pass-2 fix only reverts when
        // we transitioned FROM .off, so this must hold steady.
        await store.setStyle(.behind)
        XCTAssertEqual(store.style, .behind,
                       "pip → behind must not revert mid-flight.")

        // behind → pip — same path in reverse.
        await store.setStyle(.pip)
        XCTAssertEqual(store.style, .pip,
                       "behind → pip must not revert mid-flight.")
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

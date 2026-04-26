//
//  RecordingTests.swift
//  OpenPrompterTests
//
//  Unit tests for the recording feature (V2 Features 2 + 4).
//
//  Coverage:
//    - RecordingPhase round-trip via the codable shape (used by the Live
//      Activity payload)
//    - State machine transitions: idle → countdown(3..1) → recording;
//      cancel during countdown → idle; stop during recording → finalizing
//    - Quality / framerate / indicator pref enums round-trip
//    - ICloudCopyJob success path + immediate-failure path
//    - RecordingSession with `suppressDeviceWork: true` (mirrors Feature 1's
//      CameraStore test pattern — exercises the state machine without
//      touching real AVFoundation)
//    - RecordingFileStore directory creation and stale recording scan
//
//  No UI snapshot tests, no tests that touch the actual camera or mic.
//

import XCTest
import AVFoundation
@testable import OpenPrompter

@MainActor
final class RecordingTests: XCTestCase {

    // MARK: - Cleanup helpers

    private let recordingKeys: [String] = [
        PrefKey.recordingQuality.rawValue,
        PrefKey.recordingFramerate.rawValue,
        PrefKey.recordingMicSource.rawValue,
        PrefKey.recordingStabilization.rawValue,
        PrefKey.recordingCountdown.rawValue,
        PrefKey.recordingIndicator.rawValue,
        PrefKey.recordingSaveToScriptFolder.rawValue,
        PrefKey.labsRecording.rawValue,
        PrefKey.recordingPhotosPermissionAsked.rawValue
    ]

    private var savedValues: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        let store = UserDefaults.standard
        savedValues.removeAll(keepingCapacity: true)
        for key in recordingKeys {
            savedValues[key] = store.object(forKey: key)
            store.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        let store = UserDefaults.standard
        for key in recordingKeys {
            if case let .some(value?) = savedValues[key] {
                store.set(value, forKey: key)
            } else {
                store.removeObject(forKey: key)
            }
        }
        savedValues.removeAll()
        super.tearDown()
    }

    // MARK: - RecordingPhase round-trip codable

    func testRecordingPhaseCodableRoundTripIdle() throws {
        let phase = RecordingPhase.idle
        let encoded = try JSONEncoder().encode(phase.codableShape)
        let decodedShape = try JSONDecoder().decode(RecordingPhase.CodableShape.self, from: encoded)
        XCTAssertEqual(RecordingPhase(decodedShape), phase)
    }

    func testRecordingPhaseCodableRoundTripCountdown() throws {
        let phase = RecordingPhase.countdown(remaining: 3)
        let encoded = try JSONEncoder().encode(phase.codableShape)
        let decodedShape = try JSONDecoder().decode(RecordingPhase.CodableShape.self, from: encoded)
        XCTAssertEqual(RecordingPhase(decodedShape), phase)
    }

    func testRecordingPhaseCodableRoundTripFinalizing() throws {
        let phase = RecordingPhase.finalizing
        let encoded = try JSONEncoder().encode(phase.codableShape)
        let decodedShape = try JSONDecoder().decode(RecordingPhase.CodableShape.self, from: encoded)
        XCTAssertEqual(RecordingPhase(decodedShape), phase)
    }

    func testRecordingPhaseCodableRoundTripSaving() throws {
        let phase = RecordingPhase.saving(destinations: SaveDestinations(photos: true, scriptFolder: true))
        let encoded = try JSONEncoder().encode(phase.codableShape)
        let decodedShape = try JSONDecoder().decode(RecordingPhase.CodableShape.self, from: encoded)
        XCTAssertEqual(RecordingPhase(decodedShape), phase)
    }

    func testRecordingPhaseSimpleKeyStability() {
        // The simpleKey strings travel through the Live Activity payload —
        // breaking these renames invalidates running activities.
        XCTAssertEqual(RecordingPhase.idle.simpleKey, "idle")
        XCTAssertEqual(RecordingPhase.countdown(remaining: 1).simpleKey, "countdown")
        XCTAssertEqual(RecordingPhase.recording(startedAt: .now).simpleKey, "recording")
        XCTAssertEqual(RecordingPhase.finalizing.simpleKey, "finalizing")
        XCTAssertEqual(RecordingPhase.saving(destinations: .default).simpleKey, "saving")
        XCTAssertEqual(RecordingPhase.error("x").simpleKey, "error")
    }

    func testRecordingPhaseIsRecordingFlagDrivesTallyLight() {
        XCTAssertFalse(RecordingPhase.idle.isRecording)
        XCTAssertFalse(RecordingPhase.countdown(remaining: 3).isRecording)
        XCTAssertTrue(RecordingPhase.recording(startedAt: .now).isRecording)
        XCTAssertFalse(RecordingPhase.finalizing.isRecording)
        XCTAssertFalse(RecordingPhase.saving(destinations: .default).isRecording)
    }

    // MARK: - RecordingState transitions

    func testStartCountdownEntersCountdownPhase() {
        let state = RecordingState()
        state.startCountdown(seconds: 3)
        XCTAssertEqual(state.phase, .countdown(remaining: 3))
    }

    func testStartCountdownWithZeroSecondsGoesStraightToRecording() {
        let state = RecordingState()
        state.startCountdown(seconds: 0)
        if case .recording = state.phase { } else {
            XCTFail("Expected immediate recording phase, got \(state.phase)")
        }
    }

    func testCountdownTicksAdvanceThenRecord() {
        let state = RecordingState()
        state.startCountdown(seconds: 3)
        XCTAssertEqual(state.phase, .countdown(remaining: 3))
        state.tickCountdown()
        XCTAssertEqual(state.phase, .countdown(remaining: 2))
        state.tickCountdown()
        XCTAssertEqual(state.phase, .countdown(remaining: 1))
        state.tickCountdown()
        if case .recording = state.phase { } else {
            XCTFail("Expected recording phase after final tick, got \(state.phase)")
        }
    }

    func testCancelDuringCountdownReturnsToIdle() {
        let state = RecordingState()
        state.startCountdown(seconds: 3)
        state.cancelCountdown()
        XCTAssertEqual(state.phase, .idle)
    }

    func testCancelOutsideCountdownIsNoOp() {
        let state = RecordingState()
        state.cancelCountdown() // no-op from idle
        XCTAssertEqual(state.phase, .idle)
        state.phase = .recording(startedAt: .now)
        state.cancelCountdown() // no-op from recording
        if case .recording = state.phase { } else {
            XCTFail("cancelCountdown must not transition out of recording")
        }
    }

    func testEnterFinalizingFromRecording() {
        let state = RecordingState()
        state.phase = .recording(startedAt: .now)
        state.enterFinalizing()
        XCTAssertEqual(state.phase, .finalizing)
    }

    func testEnterFinalizingOutsideRecordingIsNoOp() {
        let state = RecordingState()
        state.enterFinalizing() // from idle
        XCTAssertEqual(state.phase, .idle)
    }

    func testFinishSavingSurfacesToast() {
        let state = RecordingState()
        state.finishSavingSuccessfully(photos: true, scriptFolder: false)
        let toast = state.consumeSavedToast()
        XCTAssertNotNil(toast)
        XCTAssertEqual(toast?.photosWritten, true)
        XCTAssertEqual(toast?.scriptFolderWritten, false)
        // Consumer is one-shot — second read returns nil.
        XCTAssertNil(state.consumeSavedToast())
    }

    func testIsRecordingComputedFlagBackwardsCompat() {
        // Feature 1's tally-light wiring binds to `isRecording`. Confirm
        // that flipping the bool drives the phase machine and vice versa.
        let state = RecordingState()
        XCTAssertFalse(state.isRecording)
        state.isRecording = true
        if case .recording = state.phase { } else {
            XCTFail("isRecording = true must move phase into recording")
        }
        state.isRecording = false
        XCTAssertEqual(state.phase, .idle)
    }

    func testToggleForDebugStillWorksForLabsToggle() {
        // CameraTests existing assertions check this — keep them green.
        let state = RecordingState()
        state.toggleForDebug()
        XCTAssertTrue(state.isRecording)
        state.toggleForDebug()
        XCTAssertFalse(state.isRecording)
    }

    func testElapsedSecondsIsZeroOutsideRecordingPhase() {
        let state = RecordingState()
        XCTAssertEqual(state.elapsedSeconds(), 0)
        state.phase = .countdown(remaining: 2)
        XCTAssertEqual(state.elapsedSeconds(), 0)
        state.phase = .finalizing
        XCTAssertEqual(state.elapsedSeconds(), 0)
    }

    func testElapsedSecondsCountsFromStartOfRecording() {
        let started = Date(timeIntervalSinceReferenceDate: 1000)
        let state = RecordingState()
        state.phase = .recording(startedAt: started)
        let now = started.addingTimeInterval(42)
        XCTAssertEqual(state.elapsedSeconds(now: now), 42)
    }

    // MARK: - Quality / framerate / indicator enums

    func testRecordingQualityRoundTrip() throws {
        for quality in RecordingQuality.allCases {
            let data = try JSONEncoder().encode(quality)
            let decoded = try JSONDecoder().decode(RecordingQuality.self, from: data)
            XCTAssertEqual(decoded, quality)
        }
    }

    func testRecordingQualityRawValueStability() {
        // The raw values are persisted to UserDefaults and mirrored to
        // iCloud KVS — renaming any of them is a breaking change.
        XCTAssertEqual(RecordingQuality.standard.rawValue, "standard")
        XCTAssertEqual(RecordingQuality.high.rawValue, "high")
    }

    func testRecordingQualityCodecIsHEVC() {
        for quality in RecordingQuality.allCases {
            XCTAssertEqual(quality.codec, .hevc, "Both tiers must be HEVC — ProRes is scoped out.")
        }
    }

    func testRecordingQualityBitrateScales() {
        let standard = RecordingQuality.standard
        let high = RecordingQuality.high
        XCTAssertGreaterThan(high.bitrate1080p, standard.bitrate1080p,
                             "High tier must have a higher 1080p bitrate.")
        let hi4K = high.bitsPerSecond(forShortDimension: 2160)
        let hi1080 = high.bitrate1080p
        XCTAssertGreaterThan(hi4K, hi1080,
                             "4K bitrate scaling must exceed 1080p.")
    }

    /// Dogfood-pass-2 bug 2a: the previous formula scaled bitrate by an
    /// inferred 16:9 long edge, which on iPhone 17's square 1×1 buffer
    /// inflated the rate ~78% (3024 short × inferred 5376 long = 16M
    /// pixels treated as the source vs the real 9.1M pixels). The result
    /// was a 213 MB / 4 second file at "Standard" — well over the 50 Mbps
    /// target this tier promises. Verify the pixel-count formula bounds
    /// the 1×1 case to a sane multiple of the 1080p baseline.
    func testRecordingQualityBitrateScalesByActualPixelCount() {
        let standard = RecordingQuality.standard
        // 1080p baseline as canonical reference.
        let baseline = standard.bitsPerSecond(forWidth: 1920, height: 1080)
        XCTAssertEqual(baseline, standard.bitrate1080p,
                       "1080p input must produce the canonical 1080p bitrate.")

        // iPhone 17 1×1 (3024×3024) — actual pixel count is ~4.4× 1080p, so
        // the bitrate should be ~4.4× the 50 Mbps baseline ≈ 220 Mbps. The
        // 3× ceiling caps it at 150 Mbps. Either way it must be well below
        // the 392 Mbps that the broken formula produced.
        let square = standard.bitsPerSecond(forWidth: 3024, height: 3024)
        XCTAssertLessThanOrEqual(square, standard.bitrate1080p * 3,
                                 "Square 1×1 must be capped at 3× the 1080p baseline.")
        XCTAssertLessThan(square, 250_000_000,
                          "1×1 bitrate must stay under 250 Mbps regardless — the broken formula produced ~392 Mbps.")
    }

    /// The High tier hits the same ceiling — a square buffer must not
    /// blow past 3× the 1080p baseline (360 Mbps max), well below the
    /// 941 Mbps the broken formula would have produced for High @ 1×1.
    func testRecordingQualityHighTierSquareBitrateBounded() {
        let high = RecordingQuality.high
        let square = high.bitsPerSecond(forWidth: 3024, height: 3024)
        XCTAssertLessThanOrEqual(square, high.bitrate1080p * 3,
                                 "High @ square must be capped at 3× the 1080p baseline.")
        XCTAssertGreaterThanOrEqual(square, high.bitrate1080p,
                                    "High @ square must still exceed 1080p — it has more pixels.")
    }

    /// Bitrate scales linearly with pixel count — twice the pixels = twice
    /// the bitrate (until the ceiling clamps it).
    func testRecordingQualityBitrateLinearInPixels() {
        let standard = RecordingQuality.standard
        let baseline = standard.bitsPerSecond(forPixelCount: 1080 * 1920)
        let half = standard.bitsPerSecond(forPixelCount: 1080 * 960)
        // Half the pixels → half the bitrate (subject to the 20 Mbps floor).
        XCTAssertLessThan(half, baseline)
    }

    /// Legacy `forShortDimension` is preserved for callers that don't have
    /// a real width/height — used by the Settings storage estimator. Must
    /// continue to assume 16:9 long edge (the picker UI's storage
    /// estimate is for the 1080p / 4K scenario, not the square sensor).
    func testRecordingQualityShortDimensionFormulaUnchangedFor16x9() {
        let standard = RecordingQuality.standard
        let s1080 = standard.bitsPerSecond(forShortDimension: 1080)
        XCTAssertEqual(s1080, standard.bitrate1080p,
                       "short-dim formula at 1080 must equal canonical 1080p bitrate.")
    }

    func testRecordingFramerateRoundTrip() throws {
        for fr in RecordingFramerate.allCases {
            let data = try JSONEncoder().encode(fr)
            let decoded = try JSONDecoder().decode(RecordingFramerate.self, from: data)
            XCTAssertEqual(decoded, fr)
        }
    }

    func testRecordingFramerateFPSValuesMatchSpec() {
        XCTAssertEqual(RecordingFramerate.fps24.fps, 24)
        XCTAssertEqual(RecordingFramerate.fps30.fps, 30)
        XCTAssertEqual(RecordingFramerate.fps60.fps, 60)
    }

    func testRecordingIndicatorPrefRoundTrip() throws {
        for pref in RecordingIndicatorPref.allCases {
            let data = try JSONEncoder().encode(pref)
            let decoded = try JSONDecoder().decode(RecordingIndicatorPref.self, from: data)
            XCTAssertEqual(decoded, pref)
        }
    }

    func testRecordingIndicatorTallyLightAllowed() {
        XCTAssertTrue(RecordingIndicatorPref.both.showsTallyLight)
        XCTAssertTrue(RecordingIndicatorPref.tallyOnly.showsTallyLight)
        XCTAssertFalse(RecordingIndicatorPref.islandOnly.showsTallyLight)
    }

    func testRecordingIndicatorLiveActivityAllowed() {
        XCTAssertTrue(RecordingIndicatorPref.both.showsLiveActivity)
        XCTAssertTrue(RecordingIndicatorPref.islandOnly.showsLiveActivity)
        XCTAssertFalse(RecordingIndicatorPref.tallyOnly.showsLiveActivity)
    }

    func testRecordingCountdownSecondsMatchSpec() {
        XCTAssertEqual(RecordingCountdown.off.seconds, 0)
        XCTAssertEqual(RecordingCountdown.three.seconds, 3)
        XCTAssertEqual(RecordingCountdown.five.seconds, 5)
    }

    // MARK: - Pref defaults match spec

    func testRecordingPrefDefaultsMatchSpec() {
        XCTAssertEqual(PrefKey.recordingQuality.defaultValue as? String, "high")
        XCTAssertEqual(PrefKey.recordingFramerate.defaultValue as? String, "fps30")
        XCTAssertEqual(PrefKey.recordingMicSource.defaultValue as? String, "builtin")
        XCTAssertEqual(PrefKey.recordingStabilization.defaultValue as? String, "off")
        XCTAssertEqual(PrefKey.recordingCountdown.defaultValue as? String, "three")
        XCTAssertEqual(PrefKey.recordingSaveToScriptFolder.defaultValue as? Bool, false)
    }

    func testRecordingPrefAccessorsRoundTrip() {
        Prefs.recordingQuality = "standard"
        XCTAssertEqual(Prefs.recordingQuality, "standard")
        Prefs.recordingFramerate = "fps60"
        XCTAssertEqual(Prefs.recordingFramerate, "fps60")
        Prefs.recordingStabilization = "cinematic"
        XCTAssertEqual(Prefs.recordingStabilization, "cinematic")
        Prefs.recordingCountdown = "five"
        XCTAssertEqual(Prefs.recordingCountdown, "five")
        Prefs.recordingSaveToScriptFolder = true
        XCTAssertEqual(Prefs.recordingSaveToScriptFolder, true)
        Prefs.recordingMicSource = "auto"
        XCTAssertEqual(Prefs.recordingMicSource, "auto")
    }

    // MARK: - ICloudCopyJob

    func testICloudCopySuccessPath() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // Make a fake recording in a sibling temp dir.
        let recording = tempDir.appendingPathComponent("take.mov")
        try Data("placeholder".utf8).write(to: recording)

        // Pretend the script lives in the same temp dir.
        let script = tempDir.appendingPathComponent("notes.md")
        try Data("# notes".utf8).write(to: script)

        let result = await ICloudCopyJob.copy(
            recording: recording,
            forScript: script,
            timestamp: Date(timeIntervalSinceReferenceDate: 1000)
        )
        switch result {
        case .success(let url):
            XCTAssertTrue(fm.fileExists(atPath: url.path))
            XCTAssertEqual(url.deletingLastPathComponent().path, tempDir.path,
                           "Copy must land in the script's parent folder.")
            XCTAssertTrue(url.lastPathComponent.hasPrefix("notes__"),
                          "Filename must use the script stem prefix.")
            XCTAssertTrue(url.lastPathComponent.hasSuffix(".mov"))
        case .failure(let err):
            XCTFail("Expected success, got \(err)")
        }
    }

    func testICloudCopyFailureSurfacesUserMessageImmediately() async {
        // Source missing → immediate failure with user-readable copy.
        let bogusSource = URL(fileURLWithPath: "/private/tmp/openprompter-tests/does-not-exist.mov")
        let bogusScript = URL(fileURLWithPath: "/private/tmp/openprompter-tests/script.md")
        let result = await ICloudCopyJob.copy(recording: bogusSource, forScript: bogusScript)
        switch result {
        case .success:
            XCTFail("Source missing must surface a failure.")
        case .failure(let err):
            XCTAssertEqual(err, .sourceMissing)
            XCTAssertFalse(err.userMessage.isEmpty,
                           "Failure must carry a user-readable message.")
        }
    }

    // MARK: - RecordingFileStore

    func testRecordingFileStoreCreatesDirectory() throws {
        // Clean state — the directory might not exist yet.
        let dir = try RecordingFileStore.ensureDirectory()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(dir.lastPathComponent, "Recordings")
    }

    func testRecordingFileStoreNewURLIsUnique() {
        let a = RecordingFileStore.newRecordingURL(now: Date(timeIntervalSinceReferenceDate: 1000))
        let b = RecordingFileStore.newRecordingURL(now: Date(timeIntervalSinceReferenceDate: 1001))
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.lastPathComponent.hasSuffix(".mov"))
    }

    func testRecordingFileStoreDiscardsStaleFiles() throws {
        // Plant a stale .mov, confirm scan finds it, then discard.
        try RecordingFileStore.ensureDirectory()
        let url = RecordingFileStore.newRecordingURL()
        try Data("stale".utf8).write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let stale = RecordingFileStore.mostRecentStaleRecording()
        XCTAssertEqual(stale?.path, url.path)

        RecordingFileStore.discardAllStaleRecordings()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - RecordingSession suppressed-device-work transitions

    func testRecordingSessionTapRECEntersCountdown() async {
        Prefs.recordingCountdown = "three"
        let state = RecordingState()
        let session = RecordingSession(
            state: state,
            cameraStore: nil,
            suppressDeviceWork: true
        )
        await session.tapREC()
        XCTAssertEqual(state.phase, .countdown(remaining: 3))
    }

    func testRecordingSessionTapRECWithCountdownOffStartsRecordingImmediately() async {
        Prefs.recordingCountdown = "off"
        let state = RecordingState()
        let session = RecordingSession(
            state: state,
            cameraStore: nil,
            suppressDeviceWork: true
        )
        await session.tapREC()
        if case .recording = state.phase { } else {
            XCTFail("Countdown off must transition straight to recording, got \(state.phase)")
        }
    }

    func testRecordingSessionTapStopFromRecordingFinalizesAndSaves() async {
        Prefs.recordingCountdown = "off"
        let state = RecordingState()
        let session = RecordingSession(
            state: state,
            cameraStore: nil,
            suppressDeviceWork: true
        )
        await session.tapREC()
        await session.tapStop()
        // After tapStop, the session should run finalize → saving → idle
        // (Photos write is bypassed in suppressDeviceWork mode and reports
        // success, so the toast surfaces and the phase returns to idle).
        XCTAssertEqual(state.phase, .idle)
        let toast = state.consumeSavedToast()
        XCTAssertNotNil(toast, "Successful save must surface a toast.")
    }

    func testRecordingSessionCancelDuringCountdownReturnsToIdle() async {
        Prefs.recordingCountdown = "three"
        let state = RecordingState()
        let session = RecordingSession(
            state: state,
            cameraStore: nil,
            suppressDeviceWork: true
        )
        await session.tapREC()
        XCTAssertEqual(state.phase, .countdown(remaining: 3))
        session.tapCancelDuringCountdown()
        XCTAssertEqual(state.phase, .idle)
    }

    // MARK: - Dimension resolution (Bug 2b: 3024×4032 smoking gun)
    //
    // `setDynamicAspectRatio` is async — `device.dynamicDimensions` reads
    // {0,0} synchronously after the call. Before the dogfood-pass-2 fix
    // the writer fell through to the native 4032×3024 formatDescription,
    // mismatching the 3024×3024 buffers that actually arrive once the
    // reshape lands. The pure helper applies the requested aspect to the
    // native dims so we get the right writer config even before the async
    // reshape publishes.
    //
    // Pure helpers — no AVFoundation device required.

    func testApplyAspectRatio1x1OnNative4x3() {
        // iPhone 17 native sensor is 4032×3024 (4:3). Asking for 1×1
        // crops the wider axis, leaving a 3024×3024 square readout.
        let result = RecordingSession.applyAspectRatio(
            rawAspect: "AVCaptureAspectRatio1x1",
            toNativeWidth: 4032,
            height: 3024
        )
        XCTAssertEqual(result?.width, 3024)
        XCTAssertEqual(result?.height, 3024)
    }

    func testApplyAspectRatio16x9OnNative4x3() {
        // 4:3 → 16:9 keeps the wider axis, crops the height.
        let result = RecordingSession.applyAspectRatio(
            rawAspect: "AVCaptureAspectRatio16x9",
            toNativeWidth: 4032,
            height: 3024
        )
        XCTAssertEqual(result?.width, 4032)
        XCTAssertEqual(result?.height, 2268,
                       "16:9 crop of 4032 wide → 2268 tall (4032×9/16).")
    }

    func testApplyAspectRatio4x3OnNative4x3() {
        // 4:3 → 4:3 leaves dims alone.
        let result = RecordingSession.applyAspectRatio(
            rawAspect: "AVCaptureAspectRatio4x3",
            toNativeWidth: 4032,
            height: 3024
        )
        XCTAssertEqual(result?.width, 4032)
        XCTAssertEqual(result?.height, 3024)
    }

    func testApplyAspectRatioReturnsNilForUnknownString() {
        XCTAssertNil(RecordingSession.applyAspectRatio(
            rawAspect: "AVCaptureAspectRatioBogus",
            toNativeWidth: 4032,
            height: 3024
        ))
    }

    func testApplyAspectRatioReturnsNilForZeroDims() {
        XCTAssertNil(RecordingSession.applyAspectRatio(
            rawAspect: "AVCaptureAspectRatio1x1",
            toNativeWidth: 0,
            height: 0
        ))
    }

    // MARK: - InAppIslandIndicator visibility (Bug 5)

    /// The in-app island pill must be visible during every phase where the
    /// system Live Activity would normally drive the Dynamic Island —
    /// countdown, recording, finalizing, saving — so the user gets a
    /// top-of-screen indicator while the app is foreground (the OS
    /// suppresses Live Activity presentations for the originating app).
    func testInAppIslandIndicatorShowsForActivePhases() {
        XCTAssertTrue(InAppIslandIndicator.shouldShow(for: .countdown(remaining: 3)),
                      "Pill must show during countdown so REC tap has immediate feedback.")
        XCTAssertTrue(InAppIslandIndicator.shouldShow(for: .recording(startedAt: .now)),
                      "Pill must show during active recording.")
        XCTAssertTrue(InAppIslandIndicator.shouldShow(for: .finalizing),
                      "Pill must show during writer finalize.")
        XCTAssertTrue(InAppIslandIndicator.shouldShow(
            for: .saving(destinations: .default)),
                      "Pill must show during Photos / iCloud save.")
    }

    /// And conversely, hide for idle / error so the user doesn't see a
    /// stray pill outside an in-flight take.
    func testInAppIslandIndicatorHidesForInactivePhases() {
        XCTAssertFalse(InAppIslandIndicator.shouldShow(for: .idle),
                       "Pill must hide when no take is in flight.")
        XCTAssertFalse(InAppIslandIndicator.shouldShow(for: .error("bad")),
                       "Pill must hide on error so the banner takes the user's focus.")
    }
}

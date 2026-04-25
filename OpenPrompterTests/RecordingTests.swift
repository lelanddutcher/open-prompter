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

    func testICloudCopySuccessPath() throws {
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

        let result = ICloudCopyJob.copy(
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

    func testICloudCopyFailureSurfacesUserMessageImmediately() {
        // Source missing → immediate failure with user-readable copy.
        let bogusSource = URL(fileURLWithPath: "/private/tmp/openprompter-tests/does-not-exist.mov")
        let bogusScript = URL(fileURLWithPath: "/private/tmp/openprompter-tests/script.md")
        let result = ICloudCopyJob.copy(recording: bogusSource, forScript: bogusScript)
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
}

//
//  AudioSessionCoordinatorTests.swift
//  OpenPrompterTests
//
//  Fix 1a — verifies the shared-audio-session coordinator that recording,
//  voice tracking, and the volume-button source negotiate through:
//   – claims win by priority (recording ≥ voice > volume observation)
//   – releasing a higher claim falls back to a lower one and re-arms
//     subscribers (the "record → stop → volume KVO comes back" fix, audit A5)
//   – interruption / route-change disruptions force a re-apply + re-arm
//   – idempotent re-claims don't spam the re-arm signal
//
//  Runs with `suppressSessionWork: true` so no real AVAudioSession hardware
//  is touched — the coordination bookkeeping and re-arm dispatch still run.
//

import XCTest
@testable import OpenPrompter

@MainActor
final class AudioSessionCoordinatorTests: XCTestCase {

    private func makeCoordinator() -> AudioSessionCoordinator {
        AudioSessionCoordinator(suppressSessionWork: true)
    }

    // A tiny owner object to key re-arm handlers by identity.
    private final class Owner {}

    // MARK: - Priority

    func testEffectiveRoleFollowsPriority() {
        let coord = makeCoordinator()
        XCTAssertNil(coord.effectiveRole)

        coord.claim(.volumeObservation, configuration: .ambientObservation)
        XCTAssertEqual(coord.effectiveRole, .volumeObservation)

        coord.claim(.voiceTracking, configuration: .capture)
        XCTAssertEqual(coord.effectiveRole, .voiceTracking)

        coord.claim(.recording, configuration: .capture)
        XCTAssertEqual(coord.effectiveRole, .recording)
    }

    func testReleasingRecordingFallsBackToVolume() {
        let coord = makeCoordinator()
        coord.claim(.volumeObservation, configuration: .ambientObservation)
        coord.claim(.recording, configuration: .capture)
        XCTAssertEqual(coord.effectiveRole, .recording)

        coord.release(.recording)
        // Volume observation still active → it wins now.
        XCTAssertEqual(coord.effectiveRole, .volumeObservation)
    }

    func testReleasingAllClaimsClearsEffectiveRole() {
        let coord = makeCoordinator()
        coord.claim(.recording, configuration: .capture)
        coord.claim(.volumeObservation, configuration: .ambientObservation)
        coord.release(.recording)
        coord.release(.volumeObservation)
        XCTAssertNil(coord.effectiveRole)
    }

    func testReleaseUnclaimedRoleIsNoOp() {
        let coord = makeCoordinator()
        coord.claim(.volumeObservation, configuration: .ambientObservation)
        // Releasing a role that was never claimed shouldn't disturb the winner.
        coord.release(.recording)
        XCTAssertEqual(coord.effectiveRole, .volumeObservation)
    }

    // MARK: - Re-arm on category change (audit A5)

    func testReArmFiresWhenEffectiveConfigChanges() {
        let coord = makeCoordinator()
        let owner = Owner()
        var reArmCount = 0
        coord.addReArmHandler({ reArmCount += 1 }, for: owner)

        // Volume claims .ambient → first application, config changed from nil.
        coord.claim(.volumeObservation, configuration: .ambientObservation)
        XCTAssertEqual(reArmCount, 1)

        // Recording claims .capture → config changes ambient → capture.
        coord.claim(.recording, configuration: .capture)
        XCTAssertEqual(reArmCount, 2)

        // Recording releases → falls back to ambient → config changes again.
        coord.release(.recording)
        XCTAssertEqual(reArmCount, 3)
    }

    func testIdempotentReclaimDoesNotSpamReArm() {
        let coord = makeCoordinator()
        let owner = Owner()
        var reArmCount = 0
        coord.addReArmHandler({ reArmCount += 1 }, for: owner)

        coord.claim(.recording, configuration: .capture)
        XCTAssertEqual(reArmCount, 1)

        // Re-claiming the SAME role with the SAME config is idempotent — the
        // applied configuration is unchanged, so no re-arm should fire (avoids
        // spamming the volume source on every recording re-activation).
        coord.claim(.recording, configuration: .capture)
        XCTAssertEqual(reArmCount, 1)
    }

    func testVoiceKeepsCaptureWhenRecordingReleases() {
        let coord = makeCoordinator()
        let owner = Owner()
        var reArmCount = 0
        coord.addReArmHandler({ reArmCount += 1 }, for: owner)

        coord.claim(.voiceTracking, configuration: .capture)   // fire 1
        coord.claim(.recording, configuration: .capture)       // same config, no fire
        XCTAssertEqual(reArmCount, 1)
        XCTAssertEqual(coord.effectiveRole, .recording)

        // Recording releases but voice still holds .capture → config unchanged
        // → no re-arm, and capture stays applied.
        coord.release(.recording)
        XCTAssertEqual(coord.effectiveRole, .voiceTracking)
        XCTAssertEqual(reArmCount, 1)
    }

    // MARK: - Disruption re-arm (interruption / route change)

    func testDisruptionForcesReArm() {
        let coord = makeCoordinator()
        let owner = Owner()
        var reArmCount = 0
        coord.addReArmHandler({ reArmCount += 1 }, for: owner)

        coord.claim(.volumeObservation, configuration: .ambientObservation)
        XCTAssertEqual(reArmCount, 1)

        // Simulate an interruption-end / route change: even though the winning
        // config is unchanged, the observer is presumed dead so a re-arm must
        // fire unconditionally.
        coord.handleSessionDisruption()
        XCTAssertEqual(reArmCount, 2)
    }

    func testDisruptionWithNoClaimsDoesNotReArm() {
        let coord = makeCoordinator()
        let owner = Owner()
        var reArmCount = 0
        coord.addReArmHandler({ reArmCount += 1 }, for: owner)

        // No active claims → a disruption has nothing to re-establish.
        coord.handleSessionDisruption()
        XCTAssertEqual(reArmCount, 0)
    }

    // MARK: - Handler registration lifecycle

    func testRemovedHandlerNoLongerFires() {
        let coord = makeCoordinator()
        let owner = Owner()
        var reArmCount = 0
        let token = coord.addReArmHandler({ reArmCount += 1 }, for: owner)

        coord.claim(.recording, configuration: .capture)
        XCTAssertEqual(reArmCount, 1)

        coord.removeReArmHandler(token)
        coord.release(.recording)                                // would fire, but handler gone
        coord.claim(.volumeObservation, configuration: .ambientObservation)
        XCTAssertEqual(reArmCount, 1)
    }
}

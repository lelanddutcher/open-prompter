//
//  PrompterViewModelRemoteTests.swift
//  OpenPrompterTests
//
//  Tests the play-start offset capture and the jumpToStartOfTake() round
//  trip, plus the handleRemoteEvent dispatcher.
//
//  Doesn't load a real script — uses an in-memory ScriptFile pointing at
//  a temp URL. The state we exercise (scroller, isPlaying, speed) is
//  independent of script content.
//

import XCTest
@testable import OpenPrompter

@MainActor
final class PrompterViewModelRemoteTests: XCTestCase {

    private func makeViewModel() -> PrompterViewModel {
        let url = URL(fileURLWithPath: "/tmp/open-prompter-test-\(UUID().uuidString).md")
        let file = ScriptFile(id: url, name: url.lastPathComponent, mtime: .now, downloadState: .current)
        let vm = PrompterViewModel(file: file)
        // Fake a viewport + content height so seek math works.
        vm.contentHeight = 1000
        vm.viewportHeight = 500
        return vm
    }

    // MARK: - playStartScrollOffset capture

    func testPlayStartCapturedOnPress() {
        let vm = makeViewModel()
        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(vm.playStartScrollOffset, 0)

        // Move the scroller and press play. The captured offset is 200.
        vm.scroller.seek(to: 200, maxOffset: vm.maxScrollOffset)
        vm.togglePlay()

        XCTAssertTrue(vm.isPlaying)
        XCTAssertEqual(vm.playStartScrollOffset, 200, accuracy: 0.001)
    }

    func testPauseDoesNotResetPlayStartOffset() {
        let vm = makeViewModel()
        vm.scroller.seek(to: 100, maxOffset: vm.maxScrollOffset)
        vm.togglePlay()                  // play, captures 100
        vm.scroller.seek(to: 300, maxOffset: vm.maxScrollOffset)
        vm.togglePlay()                  // pause — offset still 100
        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(vm.playStartScrollOffset, 100, accuracy: 0.001)
    }

    func testNewTakeAfterResumeUpdatesPlayStart() {
        // Roadmap §7 spec: "Capture the offset on every transition from
        // paused → playing, so each new take starts a new 'start position.'"
        let vm = makeViewModel()
        vm.scroller.seek(to: 50, maxOffset: vm.maxScrollOffset)
        vm.togglePlay()                  // play — capture 50
        XCTAssertEqual(vm.playStartScrollOffset, 50, accuracy: 0.001)

        vm.scroller.seek(to: 250, maxOffset: vm.maxScrollOffset)
        vm.togglePlay()                  // pause
        vm.scroller.seek(to: 400, maxOffset: vm.maxScrollOffset)
        vm.togglePlay()                  // play — NEW take, capture 400
        XCTAssertTrue(vm.isPlaying)
        XCTAssertEqual(vm.playStartScrollOffset, 400, accuracy: 0.001)
    }

    func testJumpToStartOfTakeRestoresOffset() {
        let vm = makeViewModel()
        vm.scroller.seek(to: 75, maxOffset: vm.maxScrollOffset)
        vm.togglePlay()                  // play — capture 75
        vm.scroller.seek(to: 350, maxOffset: vm.maxScrollOffset)

        vm.jumpToStartOfTake()
        XCTAssertEqual(vm.scroller.offset, 75, accuracy: 0.001)
        XCTAssertTrue(vm.isPlaying, "jumpToStartOfTake should not pause.")
    }

    // MARK: - handleRemoteEvent dispatch

    func testRestartEventGoesToZero() {
        let vm = makeViewModel()
        vm.scroller.seek(to: 250, maxOffset: vm.maxScrollOffset)
        vm.handleRemoteEvent(.restart)
        XCTAssertEqual(vm.scroller.offset, 0)
    }

    func testJumpToStartEventUsesCapturedOffset() {
        let vm = makeViewModel()
        vm.scroller.seek(to: 100, maxOffset: vm.maxScrollOffset)
        vm.togglePlay()
        vm.scroller.seek(to: 300, maxOffset: vm.maxScrollOffset)
        vm.handleRemoteEvent(.jumpToStart)
        XCTAssertEqual(vm.scroller.offset, 100, accuracy: 0.001)
    }

    func testPlayPauseEventTogglesPlayback() {
        let vm = makeViewModel()
        XCTAssertFalse(vm.isPlaying)
        vm.handleRemoteEvent(.playPause)
        XCTAssertTrue(vm.isPlaying)
        vm.handleRemoteEvent(.playPause)
        XCTAssertFalse(vm.isPlaying)
    }

    func testSpeedUpAndSpeedDownEventsBumpSpeed() {
        let vm = makeViewModel()
        let initial = vm.speed
        vm.handleRemoteEvent(.speedUp)
        XCTAssertEqual(vm.speed, initial + 5, accuracy: 0.001)
        vm.handleRemoteEvent(.speedDown)
        XCTAssertEqual(vm.speed, initial, accuracy: 0.001)
    }

    func testMirrorToggleEventFlipsHorizontalAxis() {
        let vm = makeViewModel()
        let initial = vm.mirroredHorizontal
        vm.handleRemoteEvent(.mirrorToggle)
        XCTAssertEqual(vm.mirroredHorizontal, !initial)
    }

    func testJumpForwardAndJumpBackwardSeekByHalfViewport() {
        let vm = makeViewModel()
        vm.scroller.seek(to: 300, maxOffset: vm.maxScrollOffset)
        // viewportHeight = 500, half = 250.
        vm.handleRemoteEvent(.jumpBackward)
        XCTAssertEqual(vm.scroller.offset, 50, accuracy: 0.001)
        vm.handleRemoteEvent(.jumpForward)
        XCTAssertEqual(vm.scroller.offset, 300, accuracy: 0.001)
    }
}

//
//  KeyboardConnectionMonitorTests.swift
//  OpenPrompterTests
//
//  Verifies the honest connection chip logic. v3 tightened this: "remote
//  detected" is driven ONLY by the event latch (a real input actually reached
//  the app), NOT by broad `GCKeyboard` / `GCMouse` presence — which iOS
//  reports even with no physical remote paired, producing the founder's
//  false "keyboard connected" chip. Media / volume remotes (which present as
//  neither keyboard nor mouse) latch on their first event.
//

import XCTest
@testable import OpenPrompter

@MainActor
final class KeyboardConnectionMonitorTests: XCTestCase {

    func testStartsUndetected() {
        // No events yet → not detected, regardless of any GC presence.
        let monitor = KeyboardConnectionMonitor()
        XCTAssertFalse(monitor.hasSeenRemoteEvent)
        XCTAssertFalse(monitor.isRemoteDetected,
                       "detection must require a real event, not device presence")
    }

    func testDetectionIsDrivenOnlyByEventLatch() {
        // v3 fix: detection is the event latch ALONE. Presence flags must not
        // gate it — this is what killed the false "keyboard connected" chip.
        let monitor = KeyboardConnectionMonitor()
        XCTAssertEqual(monitor.isRemoteDetected, monitor.hasSeenRemoteEvent,
                       "isRemoteDetected must equal hasSeenRemoteEvent exactly")
    }

    func testNoteRemoteEventLatchesDetection() {
        let monitor = KeyboardConnectionMonitor()
        monitor.noteRemoteEvent()
        XCTAssertTrue(monitor.hasSeenRemoteEvent)
        XCTAssertTrue(monitor.isRemoteDetected,
                      "a captured event alone should flip the chip to detected")
    }

    func testNoteRemoteEventIsIdempotent() {
        let monitor = KeyboardConnectionMonitor()
        monitor.noteRemoteEvent()
        monitor.noteRemoteEvent()
        monitor.noteRemoteEvent()
        XCTAssertTrue(monitor.hasSeenRemoteEvent)
    }
}

//
//  AutoScrollerTests.swift
//  OpenPrompterTests
//

import XCTest
@testable import OpenPrompter

@MainActor
final class AutoScrollerTests: XCTestCase {

    func testFirstTickReturnsZero() {
        let scroller = AutoScroller()
        let delta = scroller.advance(now: Date(), speed: 50)
        XCTAssertEqual(delta, 0, "First tick is baseline — no delta.")
    }

    func testSecondTickIntegratesSpeedAndTime() {
        let scroller = AutoScroller()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let t1 = Date(timeIntervalSinceReferenceDate: 0.1)
        _ = scroller.advance(now: t0, speed: 50)
        let delta = scroller.advance(now: t1, speed: 50)
        // 50 px/s * 0.1s = 5 pts
        XCTAssertEqual(delta, 5.0, accuracy: 0.001)
    }

    func testNegativeOrAbsurdDtReturnsZero() {
        let scroller = AutoScroller()
        let t0 = Date(timeIntervalSinceReferenceDate: 100)
        let future = Date(timeIntervalSinceReferenceDate: 0) // before t0
        _ = scroller.advance(now: t0, speed: 50)
        let delta = scroller.advance(now: future, speed: 50)
        XCTAssertEqual(delta, 0, "Clock jumps backwards produce no scroll.")
    }

    func testLargeDtClampsToZero() {
        // Simulates app resume after 30s — dt >= 1.0 should be discarded.
        let scroller = AutoScroller()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let t30 = Date(timeIntervalSinceReferenceDate: 30)
        _ = scroller.advance(now: t0, speed: 50)
        let delta = scroller.advance(now: t30, speed: 50)
        XCTAssertEqual(delta, 0, "Long idle produces no scroll burst.")
    }

    func testZeroSpeedReturnsZeroDelta() {
        let scroller = AutoScroller()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let t1 = Date(timeIntervalSinceReferenceDate: 0.5)
        _ = scroller.advance(now: t0, speed: 0)
        let delta = scroller.advance(now: t1, speed: 0)
        XCTAssertEqual(delta, 0)
    }

    func testNegativeSpeedClampsToZero() {
        let scroller = AutoScroller()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let t1 = Date(timeIntervalSinceReferenceDate: 0.5)
        _ = scroller.advance(now: t0, speed: -100)
        let delta = scroller.advance(now: t1, speed: -100)
        XCTAssertEqual(delta, 0, "Negative speed should not reverse scroll.")
    }

    func testApplyClampsAtMax() {
        let scroller = AutoScroller()
        scroller.apply(delta: 150, maxOffset: 100)
        XCTAssertEqual(scroller.offset, 100)
        XCTAssertTrue(scroller.didReachEnd)
    }

    func testApplyClampsAtZero() {
        let scroller = AutoScroller()
        scroller.apply(delta: -50, maxOffset: 100)
        XCTAssertEqual(scroller.offset, 0)
        XCTAssertFalse(scroller.didReachEnd)
    }

    func testApplyAccumulates() {
        let scroller = AutoScroller()
        scroller.apply(delta: 10, maxOffset: 100)
        scroller.apply(delta: 20, maxOffset: 100)
        scroller.apply(delta: 15, maxOffset: 100)
        XCTAssertEqual(scroller.offset, 45)
        XCTAssertFalse(scroller.didReachEnd)
    }

    func testResetClearsState() {
        let scroller = AutoScroller()
        scroller.apply(delta: 50, maxOffset: 100)
        scroller.reset()
        XCTAssertEqual(scroller.offset, 0)
        XCTAssertFalse(scroller.didReachEnd)
    }

    func testSeekClamps() {
        let scroller = AutoScroller()
        scroller.seek(to: 200, maxOffset: 100)
        XCTAssertEqual(scroller.offset, 100)
        scroller.seek(to: -50, maxOffset: 100)
        XCTAssertEqual(scroller.offset, 0)
    }

    // MARK: - Post-review additions

    func testSeekDuringPlayResetsTickBaseline() {
        let scroller = AutoScroller()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let t1 = Date(timeIntervalSinceReferenceDate: 0.1)
        _ = scroller.advance(now: t0, speed: 50)
        _ = scroller.advance(now: t1, speed: 50)
        scroller.apply(delta: 5, maxOffset: 200)

        scroller.seek(to: 100, maxOffset: 200)
        XCTAssertEqual(scroller.offset, 100)
        XCTAssertFalse(scroller.didReachEnd)

        let t2 = Date(timeIntervalSinceReferenceDate: 0.2)
        let delta = scroller.advance(now: t2, speed: 50)
        XCTAssertEqual(delta, 0, "First tick after seek must be baseline.")
    }

    func testSpeedChangeMidPlayIntegratesCorrectly() {
        let scroller = AutoScroller()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let t1 = Date(timeIntervalSinceReferenceDate: 0.5)
        let t2 = Date(timeIntervalSinceReferenceDate: 1.0)

        _ = scroller.advance(now: t0, speed: 100)
        let d1 = scroller.advance(now: t1, speed: 100)
        // dt clamp is < 1.0; 0.5 * 100 = 50 pts
        scroller.apply(delta: d1, maxOffset: 1000)
        XCTAssertEqual(scroller.offset, 50, accuracy: 0.01)

        let d2 = scroller.advance(now: t2, speed: 20)
        // 0.5 * 20 = 10 pts
        scroller.apply(delta: d2, maxOffset: 1000)
        XCTAssertEqual(scroller.offset, 60, accuracy: 0.01)
    }

    func testRapidResetLoopStaysConsistent() {
        let scroller = AutoScroller()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let t1 = Date(timeIntervalSinceReferenceDate: 0.1)
        for _ in 0..<100 {
            _ = scroller.advance(now: t0, speed: 50)
            _ = scroller.advance(now: t1, speed: 50)
            scroller.apply(delta: 200, maxOffset: 100)
            XCTAssertTrue(scroller.didReachEnd)
            scroller.reset()
            XCTAssertEqual(scroller.offset, 0)
            XCTAssertFalse(scroller.didReachEnd)
        }
        let delta = scroller.advance(now: t1, speed: 50)
        XCTAssertEqual(delta, 0, "Post-reset first tick must be baseline.")
    }
}

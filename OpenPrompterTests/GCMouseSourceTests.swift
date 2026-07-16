//
//  GCMouseSourceTests.swift
//  OpenPrompterTests
//
//  Verifies the pointer / scroll delta integration for the mouse-class remote
//  source (BLE-M5 Capture.md). The founder's D-pad emits pointer axis streams;
//  this source integrates them into evenly-spaced one-line scroll steps.
//
//  Pure logic — `handlePointerDelta` / `handleScrollDelta` are `internal` and
//  drive the accumulator without a live GCMouse.
//

import XCTest
@testable import OpenPrompter

@MainActor
final class GCMouseSourceTests: XCTestCase {

    private func makeStore() -> RemoteBindingStore {
        let suite = "GCMouseSourceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return RemoteBindingStore(defaults: defaults)
    }

    private func makeSource(bus: RemoteEventBus) -> GCMouseSource {
        GCMouseSource(bus: bus, store: makeStore())
    }

    // MARK: - Threshold crossing

    func testSubThresholdDeltaEmitsNothing() {
        let source = makeSource(bus: RemoteEventBus())
        // threshold 10; total 8 < 10 → no step.
        let steps = source.handlePointerDelta(8, threshold: 10)
        XCTAssertEqual(steps, 0)
    }

    func testAccumulatedDeltaCrossesThreshold() {
        let source = makeSource(bus: RemoteEventBus())
        // 6 + 6 = 12 ≥ 10 → exactly one step, 2 remainder carried.
        XCTAssertEqual(source.handlePointerDelta(6, threshold: 10), 0)
        XCTAssertEqual(source.handlePointerDelta(6, threshold: 10), 1)
        // Another 8 + 2 remainder = 10 → one more step.
        XCTAssertEqual(source.handlePointerDelta(8, threshold: 10), 1)
    }

    func testLargeDeltaEmitsMultipleSteps() {
        let source = makeSource(bus: RemoteEventBus())
        // 35 / 10 = 3 whole steps.
        XCTAssertEqual(source.handlePointerDelta(35, threshold: 10), 3)
    }

    func testNegativeAndPositiveDirectionsBothStep() {
        let source = makeSource(bus: RemoteEventBus())
        XCTAssertEqual(source.handlePointerDelta(-20, threshold: 10), 2)
        // Reverse direction from the leftover (0) — 20 up.
        XCTAssertEqual(source.handlePointerDelta(20, threshold: 10), 2)
    }

    // MARK: - Emitted event direction

    func testPositiveTravelEmitsScrollUp() async {
        let bus = RemoteEventBus()
        let source = makeSource(bus: bus)
        var iterator = bus.events.makeAsyncIterator()
        source.handlePointerDelta(15, threshold: 10) // +15 → scrollUp
        let event = await iterator.next()
        XCTAssertEqual(event, .scrollUp)
    }

    func testNegativeTravelEmitsScrollDown() async {
        let bus = RemoteEventBus()
        let source = makeSource(bus: bus)
        var iterator = bus.events.makeAsyncIterator()
        source.handlePointerDelta(-15, threshold: 10) // -15 → scrollDown
        let event = await iterator.next()
        XCTAssertEqual(event, .scrollDown)
    }

    // MARK: - Scroll wheel path uses its own accumulator

    func testScrollWheelIntegratesSeparately() {
        let source = makeSource(bus: RemoteEventBus())
        // Pointer accumulator and scroll accumulator are independent, so a
        // half-step on each does NOT combine into a full step.
        XCTAssertEqual(source.handlePointerDelta(0.6, threshold: 1), 0)
        XCTAssertEqual(source.handleScrollDelta(0.6, threshold: 1), 0)
        // Each needs its own second half to step.
        XCTAssertEqual(source.handleScrollDelta(0.6, threshold: 1), 1)
    }
}

//
//  VolumeEventSourceTests.swift
//  OpenPrompterTests
//
//  Fix 1a — press-oriented volume handling. Verifies:
//   – ANY volume change is treated as ONE press regardless of direction
//     (the BLE-M5 shutter alternates Up/Down every press — a signed delta
//     would misfire; BLE-M5 Capture.md)
//   – leading-edge debounce collapses a press's trailing echo (~120 ms)
//   – the baseline is nudged off the rail so a press at max volume still
//     registers as a change (audit A2)
//   – an identical reseed value publishes nothing
//
//  These drive the internal `handle(newVolume:now:)` / `seedBaseline(_:)`
//  seams with an injected clock, so no live `outputVolume` KVO or real
//  AVAudioSession is required.
//

import XCTest
@testable import OpenPrompter

@MainActor
final class VolumeEventSourceTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suiteName = "VolumeEventSourceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// Build a source wired to a fresh bus + default bindings, plus a
    /// collector task that records every published event. The volume source
    /// is never `start()`-ed, so no audio session or KVO is created — we only
    /// exercise the pure press logic.
    private func makeSource() -> (VolumeEventSource, RemoteEventBus, RemoteBindingStore) {
        let bus = RemoteEventBus()
        let store = RemoteBindingStore(defaults: makeDefaults())
        let coordinator = AudioSessionCoordinator(suppressSessionWork: true)
        let source = VolumeEventSource(bus: bus, store: store, coordinator: coordinator)
        return (source, bus, store)
    }

    /// Collect exactly `count` events from a bus with a timeout so a missing
    /// publish fails fast instead of hanging the suite.
    private func collect(_ count: Int, from bus: RemoteEventBus) -> Task<[RemoteEvent], Never> {
        Task {
            var received: [RemoteEvent] = []
            for await event in bus.events {
                received.append(event)
                if received.count == count { break }
            }
            return received
        }
    }

    // MARK: - Direction-agnostic press

    func testVolumeUpChangePublishesPlayPause() async {
        let (source, bus, _) = makeSource()
        let collector = collect(1, from: bus)
        source.seedBaseline(0.5)

        // A change upward.
        source.handle(newVolume: 0.6, now: Date(timeIntervalSince1970: 100))

        let result = await collector.value
        XCTAssertEqual(result, [.playPause])
    }

    func testVolumeDownChangeAlsoPublishesPlayPause() async {
        // Direction must NOT matter — the shutter alternates Up/Down. A
        // downward change is still exactly one press → .playPause.
        let (source, bus, _) = makeSource()
        let collector = collect(1, from: bus)
        source.seedBaseline(0.5)

        source.handle(newVolume: 0.4, now: Date(timeIntervalSince1970: 100))

        let result = await collector.value
        XCTAssertEqual(result, [.playPause])
    }

    func testAlternatingUpDownEachCountAsOnePress() async {
        // Emulate the BLE-M5: Up, Down, Up across three well-separated presses.
        let (source, bus, _) = makeSource()
        let collector = collect(3, from: bus)
        source.seedBaseline(0.5)

        source.handle(newVolume: 0.6, now: Date(timeIntervalSince1970: 100))
        source.handle(newVolume: 0.5, now: Date(timeIntervalSince1970: 101))
        source.handle(newVolume: 0.6, now: Date(timeIntervalSince1970: 102))

        let result = await collector.value
        XCTAssertEqual(result, [.playPause, .playPause, .playPause])
    }

    // MARK: - Debounce

    func testTrailingEchoWithinWindowIsDebounced() async {
        // A press at t=100.0, its echo at t=100.040 (inside the ~120 ms
        // window), then a genuine second press far later at t=200.0. If the
        // echo were NOT debounced there would be THREE publishes; because it
        // is, there are exactly TWO. Bind a distinct event to prove ordering
        // isn't the confound — both real changes map to .playPause.
        let (source, bus, _) = makeSource()
        var received: [RemoteEvent] = []
        let collector = Task { () -> [RemoteEvent] in
            for await event in bus.events {
                received.append(event)
                if received.count == 2 { break }
            }
            return received
        }
        source.seedBaseline(0.5)

        source.handle(newVolume: 0.6, now: Date(timeIntervalSince1970: 100.000))  // press 1
        source.handle(newVolume: 0.7, now: Date(timeIntervalSince1970: 100.040))  // echo → dropped
        source.handle(newVolume: 0.9, now: Date(timeIntervalSince1970: 200.000))  // press 2

        let result = await collector.value
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result, [.playPause, .playPause])
    }

    func testTwoPressesOutsideWindowBothFire() async {
        let (source, bus, _) = makeSource()
        let collector = collect(2, from: bus)
        source.seedBaseline(0.5)

        source.handle(newVolume: 0.6, now: Date(timeIntervalSince1970: 100.0))
        source.handle(newVolume: 0.7, now: Date(timeIntervalSince1970: 100.5))

        let result = await collector.value
        XCTAssertEqual(result, [.playPause, .playPause])
    }

    // MARK: - No-change guard

    func testIdenticalValueDoesNotPublish() async {
        let (source, bus, _) = makeSource()
        let collector = collect(1, from: bus)
        source.seedBaseline(0.5)

        // A reseed delivering the same cached value must publish nothing.
        source.handle(newVolume: source.currentBaselineForTesting, now: Date(timeIntervalSince1970: 100))
        // Now a real change unblocks the single-event collector.
        source.handle(newVolume: 0.99, now: Date(timeIntervalSince1970: 200))

        let result = await collector.value
        XCTAssertEqual(result, [.playPause])
    }

    // MARK: - Rail nudge (audit A2)

    func testBaselineNudgedOffMaxRail() {
        // At the max rail (1.0), the seeded baseline must be strictly below 1.0
        // so a Volume-Up press that reads 1.0 still registers as a change.
        XCTAssertLessThan(VolumeEventSource.nudgedOffRail(1.0), 1.0)
        XCTAssertGreaterThan(VolumeEventSource.nudgedOffRail(1.0), 0.9)
    }

    func testBaselineNudgedOffMinRail() {
        XCTAssertGreaterThan(VolumeEventSource.nudgedOffRail(0.0), 0.0)
        XCTAssertLessThan(VolumeEventSource.nudgedOffRail(0.0), 0.1)
    }

    func testMidRangeVolumeNotNudged() {
        XCTAssertEqual(VolumeEventSource.nudgedOffRail(0.5), 0.5, accuracy: 0.0001)
    }

    func testPressAtMaxRailStillRegisters() async {
        // The concrete rail scenario: system volume pinned at 1.0, user presses
        // Volume Up (KVO delivers 1.0). Because start() nudges the baseline to
        // ~0.9375, the 1.0 read differs → one press fires.
        let (source, bus, _) = makeSource()
        let collector = collect(1, from: bus)
        source.seedBaseline(1.0)   // nudges to 1.0 - 1/16

        source.handle(newVolume: 1.0, now: Date(timeIntervalSince1970: 100))

        let result = await collector.value
        XCTAssertEqual(result, [.playPause])
    }

    // MARK: - Binding respected

    func testRemappedVolumeUpKeyIsHonored() async {
        let (source, bus, store) = makeSource()
        store.setBinding(.mirrorToggle, for: .volumeUp)
        let collector = collect(1, from: bus)
        source.seedBaseline(0.5)

        source.handle(newVolume: 0.6, now: Date(timeIntervalSince1970: 100))

        let result = await collector.value
        XCTAssertEqual(result, [.mirrorToggle])
    }

    func testUnboundVolumeUpPublishesNothing() async {
        let (source, bus, store) = makeSource()
        store.setBinding(nil, for: .volumeUp)   // clear the binding
        source.seedBaseline(0.5)

        // First (unbound) change → nothing. Rebind, then a second change fires
        // so the single-event collector has something to observe.
        source.handle(newVolume: 0.6, now: Date(timeIntervalSince1970: 100))
        store.setBinding(.playPause, for: .volumeUp)
        let collector = collect(1, from: bus)
        source.handle(newVolume: 0.7, now: Date(timeIntervalSince1970: 200))

        let result = await collector.value
        XCTAssertEqual(result, [.playPause])
    }
}

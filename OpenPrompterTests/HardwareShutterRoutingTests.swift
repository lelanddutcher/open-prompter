//
//  HardwareShutterRoutingTests.swift
//  OpenPrompterTests
//
//  Verifies the v3 unification: the hardware shutter no longer hardwires to
//  record — it runs its BOUND action through the same binding system every
//  other remote source uses, and RECORD is a bindable action reachable from
//  ANY button (incl. the shutter). "The wizard decides everything."
//
//  The view-layer `handleHardwareShutter()` resolves `.volumeUp` (the
//  canonical "shutter pressed" key, shared with VolumeEventSource) through the
//  store and publishes the result onto the bus. These tests exercise that
//  contract at the store + bus + VM-dispatch level (the parts that carry the
//  behaviour), which is where a regression would actually bite.
//

import XCTest
@testable import OpenPrompter

@MainActor
final class HardwareShutterRoutingTests: XCTestCase {

    private func makeStore() -> RemoteBindingStore {
        let suite = "HardwareShutterRoutingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return RemoteBindingStore(defaults: defaults)
    }

    private func makeViewModel() -> PrompterViewModel {
        let url = URL(fileURLWithPath: "/tmp/open-prompter-hw-\(UUID().uuidString).md")
        let file = ScriptFile(id: url, name: url.lastPathComponent, mtime: .now, downloadState: .current)
        let vm = PrompterViewModel(file: file)
        vm.contentHeight = 1000
        vm.viewportHeight = 500
        return vm
    }

    /// Mirrors the view's `handleHardwareShutter()`: resolve `.volumeUp` from
    /// the store and publish it onto the bus. Exercising it here proves the
    /// routing contract without a UIViewRepresentable.
    private func simulateHardwareShutter(store: RemoteBindingStore, bus: RemoteEventBus) {
        guard let event = store.event(for: .volumeUp) else { return }
        bus.publish(event)
    }

    // MARK: - shutter runs its BOUND action

    func testShutterDefaultsToPlayPauseNotRecord() {
        // Fresh-remote default: the hardware shutter → play/pause, NOT record.
        // This is the whole point of the unification — the shutter is no
        // longer hardwired to recording.
        let store = makeStore()
        XCTAssertEqual(store.event(for: .volumeUp), .playPause,
                       "the shutter's default bound action must be play/pause")
    }

    func testShutterPressPublishesBoundEvent() async {
        let store = makeStore()
        let bus = RemoteEventBus()
        let collector = Task { () -> RemoteEvent? in
            for await event in bus.events { return event }
            return nil
        }
        simulateHardwareShutter(store: store, bus: bus)
        let received = await collector.value
        XCTAssertEqual(received, .playPause,
                       "a shutter press must publish the bound event, default play/pause")
    }

    func testRebindingShutterToRecordMakesItRecord() async {
        // The founder wants the shutter to be able to do Record instead of
        // Play/Pause — the wizard's RECORD slot (or advanced picker) binds
        // .volumeUp to .recordToggle. After that, a shutter press records.
        let store = makeStore()
        store.setBinding(.recordToggle, for: .volumeUp)
        let bus = RemoteEventBus()
        let collector = Task { () -> RemoteEvent? in
            for await event in bus.events { return event }
            return nil
        }
        simulateHardwareShutter(store: store, bus: bus)
        let received = await collector.value
        XCTAssertEqual(received, .recordToggle,
                       "after rebinding, the shutter must perform record, not play/pause")
    }

    func testUnboundShutterPublishesNothing() async {
        let store = makeStore()
        store.setBinding(nil, for: .volumeUp)   // clear the shutter binding
        let bus = RemoteEventBus()
        var received: [RemoteEvent] = []
        let collector = Task {
            for await event in bus.events { received.append(event) }
        }
        simulateHardwareShutter(store: store, bus: bus)
        // Nothing was published; give the (empty) stream a beat then cancel.
        try? await Task.sleep(nanoseconds: 20_000_000)
        collector.cancel()
        XCTAssertTrue(received.isEmpty,
                      "an unbound shutter must publish nothing")
    }

    // MARK: - .recordToggle dispatches to the record handler

    func testRecordToggleEventInvokesOnRecordToggle() {
        let vm = makeViewModel()
        var fired = 0
        vm.onRecordToggle = { fired += 1 }
        vm.handleRemoteEvent(.recordToggle)
        XCTAssertEqual(fired, 1,
                       ".recordToggle must route to the record dispatch closure")
    }

    func testRecordToggleIsNoOpWhenHandlerUnset() {
        // No recording chip on screen → onRecordToggle is nil → silent no-op,
        // exactly like the on-screen chip which isn't shown then. Must not
        // touch scroll / playback state.
        let vm = makeViewModel()
        vm.scroller.seek(to: 200, maxOffset: vm.maxScrollOffset)
        let offsetBefore = vm.scroller.offset
        let playingBefore = vm.isPlaying
        vm.onRecordToggle = nil
        vm.handleRemoteEvent(.recordToggle)   // must not crash / mutate
        XCTAssertEqual(vm.scroller.offset, offsetBefore)
        XCTAssertEqual(vm.isPlaying, playingBefore)
    }

    func testRecordToggleDoesNotTogglePlayback() {
        // Guard against a copy-paste regression that maps recordToggle to
        // playPause. Record and play must be independent actions.
        let vm = makeViewModel()
        var recordFired = false
        vm.onRecordToggle = { recordFired = true }
        XCTAssertFalse(vm.isPlaying)
        vm.handleRemoteEvent(.recordToggle)
        XCTAssertFalse(vm.isPlaying, "recordToggle must NOT start playback")
        XCTAssertTrue(recordFired)
    }
}

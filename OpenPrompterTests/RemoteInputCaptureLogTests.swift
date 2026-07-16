//
//  RemoteInputCaptureLogTests.swift
//  OpenPrompterTests
//
//  Tests the DEBUG "learn my remote" capture log (audit fix 3 / §5): the cap
//  drops oldest, an unmapped key logs `resolvedRemoteKey` but `nil` bound
//  event (proving capture happens before the binding gate), and export
//  round-trips through Codable.
//

#if DEBUG

import XCTest
@testable import OpenPrompter

@MainActor
final class RemoteInputCaptureLogTests: XCTestCase {

    private func makeStore() -> RemoteBindingStore {
        let suite = "RemoteInputCaptureLogTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return RemoteBindingStore(defaults: defaults)
    }

    private func entry(_ descriptor: String) -> CapturedRemoteInput {
        CapturedRemoteInput(
            timestamp: Date(),
            source: "keyboard",
            rawDescriptor: descriptor,
            resolvedRemoteKey: "kb.\(descriptor)",
            boundEvent: nil
        )
    }

    func testNewestEntryIsFirst() {
        let log = RemoteInputCaptureLog()
        log.record(entry("a"))
        log.record(entry("b"))
        XCTAssertEqual(log.entries.first?.rawDescriptor, "b")
        XCTAssertEqual(log.entries.last?.rawDescriptor, "a")
    }

    func testCapDropsOldest() {
        let log = RemoteInputCaptureLog()
        for i in 0..<(RemoteInputCaptureLog.maxEntries + 25) {
            log.record(entry("k\(i)"))
        }
        XCTAssertEqual(log.entries.count, RemoteInputCaptureLog.maxEntries)
        // Newest is at the front; the very first records were dropped.
        XCTAssertEqual(log.entries.first?.rawDescriptor,
                       "k\(RemoteInputCaptureLog.maxEntries + 24)")
        XCTAssertFalse(log.entries.contains { $0.rawDescriptor == "k0" })
    }

    func testUnmappedKeyLogsKeyButNilEvent() throws {
        let store = makeStore()
        store.setBinding(nil, for: .letter("z")) // ensure unmapped
        let log = RemoteInputCaptureLog()
        log.recordKey(.letter("z"), source: "keyboard", store: store)

        let recorded = try XCTUnwrap(log.entries.first)
        XCTAssertEqual(recorded.resolvedRemoteKey, "kb.letter.z")
        XCTAssertNil(recorded.boundEvent,
                     "an unmapped key must still be captured with a nil bound event")
    }

    func testMappedKeyLogsBoundEvent() {
        let store = makeStore()
        let log = RemoteInputCaptureLog()
        log.recordKey(.space, source: "keyboard", store: store) // space → playPause default
        XCTAssertEqual(log.entries.first?.boundEvent, RemoteEvent.playPause.rawValue)
    }

    func testScrollEventLogsWithoutKey() {
        let log = RemoteInputCaptureLog()
        log.recordEvent(.scrollUp, source: "mouse", rawDescriptor: "pointer up")
        let e = log.entries.first
        XCTAssertNil(e?.resolvedRemoteKey)
        XCTAssertEqual(e?.boundEvent, RemoteEvent.scrollUp.rawValue)
        XCTAssertEqual(e?.source, "mouse")
    }

    func testClearEmptiesLog() {
        let log = RemoteInputCaptureLog()
        log.record(entry("a"))
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testCodableRoundTrip() throws {
        let original = [entry("a"), entry("b")]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([CapturedRemoteInput].self, from: data)
        XCTAssertEqual(decoded.map(\.rawDescriptor), ["a", "b"])
    }
}

#endif

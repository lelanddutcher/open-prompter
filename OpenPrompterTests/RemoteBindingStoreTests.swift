//
//  RemoteBindingStoreTests.swift
//  OpenPrompterTests
//
//  Verifies that:
//  – the documented default-binding table seeds correctly from a fresh store
//  – setBinding / lookup / clear work
//  – persistence round-trips through an in-memory UserDefaults
//  – resetToDefaults restores every default after arbitrary edits
//

import XCTest
@testable import OpenPrompter

@MainActor
final class RemoteBindingStoreTests: XCTestCase {

    // Distinct suite per test so writes from one don't leak into another.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "RemoteBindingStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testDefaultsLoadedOnFirstUse() {
        // Remote-nav pass (audit fix 4 / R3): a d-pad NAVIGATES by default.
        // Up/Down step one line, Left/Right jump by section, Page keys are
        // the coarse half-screen leap. Speed control moved to j/k so it stays
        // reachable after the arrows were repurposed.
        let store = RemoteBindingStore(defaults: makeDefaults())
        XCTAssertEqual(store.event(for: .space), .playPause)
        XCTAssertEqual(store.event(for: .return), .playPause)
        XCTAssertEqual(store.event(for: .arrowUp), .lineUp)
        XCTAssertEqual(store.event(for: .arrowDown), .lineDown)
        XCTAssertEqual(store.event(for: .arrowLeft), .prevSection)
        XCTAssertEqual(store.event(for: .arrowRight), .nextSection)
        XCTAssertEqual(store.event(for: .pageUp), .jumpBackward)
        XCTAssertEqual(store.event(for: .pageDown), .jumpForward)
        XCTAssertEqual(store.event(for: .letter("j")), .speedDown)
        XCTAssertEqual(store.event(for: .letter("k")), .speedUp)
        XCTAssertEqual(store.event(for: .keypadEnter), .playPause)
        XCTAssertEqual(store.event(for: .keypadMinus), .speedDown)
        XCTAssertEqual(store.event(for: .keypadPlus), .speedUp)
        XCTAssertNil(store.event(for: .keypadDigit("1")))
    }

    func testPointerButtonDefaults() {
        // The founder's BLE-M5 D-pad center / aux shutter are digitizer taps
        // → mouse clicks. Primary tap plays/pauses; aux jumps to take start.
        let store = RemoteBindingStore(defaults: makeDefaults())
        XCTAssertEqual(store.event(for: .mouseClick), .playPause)
        XCTAssertEqual(store.event(for: .mouseRightClick), .jumpToStart)
        XCTAssertEqual(store.event(for: .mouseMiddleClick), .mirrorToggle)
    }

    func testNovelJumpToStartBindingDefault() {
        // The differentiating Feature 7 default — the "B" key returns to
        // the take's start. This test guards the spec.
        let store = RemoteBindingStore(defaults: makeDefaults())
        XCTAssertEqual(store.event(for: .letter("b")), .jumpToStart)
    }

    func testMirrorAndRestartDefaults() {
        let store = RemoteBindingStore(defaults: makeDefaults())
        XCTAssertEqual(store.event(for: .letter("m")), .mirrorToggle)
        XCTAssertEqual(store.event(for: .letter("r")), .restart)
    }

    func testSetBindingPersistsAcrossInstances() {
        let defaults = makeDefaults()
        let store1 = RemoteBindingStore(defaults: defaults)
        store1.setBinding(.mirrorToggle, for: .space)

        let store2 = RemoteBindingStore(defaults: defaults)
        XCTAssertEqual(store2.event(for: .space), .mirrorToggle)
    }

    func testSetBindingNilClearsBinding() {
        let store = RemoteBindingStore(defaults: makeDefaults())
        XCTAssertNotNil(store.event(for: .space))
        store.setBinding(nil, for: .space)
        XCTAssertNil(store.event(for: .space))
    }

    func testRebindLetter() {
        let store = RemoteBindingStore(defaults: makeDefaults())
        XCTAssertEqual(store.event(for: .letter("b")), .jumpToStart)
        store.setBinding(.mirrorToggle, for: .letter("b"))
        XCTAssertEqual(store.event(for: .letter("b")), .mirrorToggle)
    }

    func testResetToDefaultsRestoresEntireTable() {
        let defaults = makeDefaults()
        let store = RemoteBindingStore(defaults: defaults)
        // Mutate.
        store.setBinding(.mirrorToggle, for: .space)
        store.setBinding(nil, for: .arrowUp)
        store.setBinding(.restart, for: .letter("x"))
        // Reset.
        store.resetToDefaults()
        // Defaults are back.
        XCTAssertEqual(store.event(for: .space), .playPause)
        XCTAssertEqual(store.event(for: .arrowUp), .lineUp)
        // Letter("x") was never a default — should be cleared.
        XCTAssertNil(store.event(for: .letter("x")))
    }

    func testKeyFromIDRoundTrip() {
        let cases: [RemoteKey] = [
            .space, .return, .escape, .tab,
            .arrowUp, .arrowDown, .arrowLeft, .arrowRight,
            .pageUp, .pageDown,
            .digit("0"), .digit("5"), .digit("9"),
            .letter("a"), .letter("b"), .letter("z"),
            .keypadDigit("0"), .keypadDigit("5"), .keypadDigit("9"),
            .keypadNumLock, .keypadDivide, .keypadMultiply,
            .keypadMinus, .keypadPlus, .keypadEnter,
            .keypadDecimal, .keypadEqual,
            .mediaPlayPause, .mediaNextTrack, .mediaPrevTrack,
            .volumeUp, .volumeDown,
            .mouseClick, .mouseRightClick, .mouseMiddleClick
        ]
        for key in cases {
            let id = key.id
            XCTAssertEqual(
                RemoteBindingStore.keyFromID(id),
                key,
                "keyFromID failed for \(id)"
            )
        }
    }

    func testUnknownStoredKeysAreDroppedGracefully() {
        // Simulate a future build that wrote an unknown key id; the
        // current build should still load with the known entries plus
        // fall back to defaults if everything was unknown.
        let defaults = makeDefaults()
        let storedJSON: [[String: String]] = [
            ["keyID": "kb.space",     "event": "playPause"],
            ["keyID": "kb.unknown",   "event": "speedUp"]
        ]
        // Manually encode through the same encoder shape the store uses.
        struct Entry: Codable { let keyID: String; let event: RemoteEvent }
        let entries = storedJSON.map { dict in
            Entry(
                keyID: dict["keyID"]!,
                event: RemoteEvent(rawValue: dict["event"]!)!
            )
        }
        let data = try! JSONEncoder().encode(entries)
        defaults.set(data, forKey: RemoteBindingStore.storageKey)

        let store = RemoteBindingStore(defaults: defaults)
        XCTAssertEqual(store.event(for: .space), .playPause)
        // The unknown entry was dropped without affecting the rest.
    }

    // MARK: - rawKey catch-all (3.2)
    //
    // Any GCKeyCode with no named case now falls back to `.rawKey` instead of
    // being dropped before `onCapture`, which previously left the
    // learn-your-remote wizard waiting forever on function keys, Home/End, and
    // most punctuation — and made programmable DIY controllers unbindable.

    func testRawKeyIDRoundTrips() {
        let key = RemoteKey.rawKey(104)             // 0x68 = F13
        XCTAssertEqual(key.id, "kb.raw.104")
        XCTAssertEqual(RemoteBindingStore.keyFromID("kb.raw.104"), key,
                       "A rawKey binding must survive a persistence round trip.")
    }

    func testRawKeyIsLabelledForThePicker() {
        // An unlabelled key would render blank in the bindings list.
        XCTAssertFalse(RemoteKey.rawKey(104).displayName.isEmpty)
        XCTAssertEqual(RemoteKey.rawKey(104).displayName, "Key 0x68")
    }

    func testRawKeyBindsAndResolvesLikeAnyOtherKey() {
        let defaults = makeDefaults()
        let store = RemoteBindingStore(defaults: defaults)
        let f13 = RemoteKey.rawKey(104)

        store.setBinding(.jumpToEnd, for: f13)
        XCTAssertEqual(store.event(for: f13), .jumpToEnd)

        // And survives a fresh store reading the same defaults.
        let reloaded = RemoteBindingStore(defaults: defaults)
        XCTAssertEqual(reloaded.event(for: f13), .jumpToEnd,
                       "A rawKey binding must persist across store instances.")
    }

    func testDistinctRawKeyCodesAreDistinctKeys() {
        XCTAssertNotEqual(RemoteKey.rawKey(104), RemoteKey.rawKey(105))
    }
}

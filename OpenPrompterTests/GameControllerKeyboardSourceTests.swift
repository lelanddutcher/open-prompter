//
//  GameControllerKeyboardSourceTests.swift
//  OpenPrompterTests
//
//  Verifies the GCKeyCode → RemoteKey mapping and the publish-through-bus
//  path for the focus-independent keyboard source (audit fix 2 / R2).
//
//  Pure logic — no live GCKeyboard required. `remoteKey(from:)` and
//  `letter(from:)` are static, and `handle(keyCode:)` runs against an
//  in-memory bus + binding store.
//

import XCTest
import GameController
@testable import OpenPrompter

@MainActor
final class GameControllerKeyboardSourceTests: XCTestCase {

    private func makeStore() -> RemoteBindingStore {
        let suite = "GCKeyboardSourceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return RemoteBindingStore(defaults: defaults)
    }

    // MARK: - Navigation key mapping

    func testNavigationKeysMap() {
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .spacebar), .space)
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .returnOrEnter), .return)
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .escape), .escape)
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .tab), .tab)
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .upArrow), .arrowUp)
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .downArrow), .arrowDown)
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .leftArrow), .arrowLeft)
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .rightArrow), .arrowRight)
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .pageUp), .pageUp)
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .pageDown), .pageDown)
    }

    // MARK: - 10-key / digit mapping

    func testDigitKeysMap() {
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .one), .digit("1"))
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .zero), .digit("0"))
        XCTAssertEqual(GameControllerKeyboardSource.digit(from: .nine), "9")
    }

    func testKeypadKeysMap() {
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .keypadEnter), .keypadEnter)
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .keypadPlus), .keypadPlus)
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .keypadHyphen), .keypadMinus)
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .keypadSlash), .keypadDivide)
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .keypadAsterisk), .keypadMultiply)
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .keypadPeriod), .keypadDecimal)
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .keypadEqualSign), .keypadEqual)
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .keypadNumLock), .keypadNumLock)
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .keypad1), .keypadDigit("1"))
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .keypad0), .keypadDigit("0"))
        XCTAssertEqual(GameControllerKeyboardSource.keypadDigit(from: .keypad9), "9")
    }

    // MARK: - Letter mapping

    func testLetterKeysMap() {
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .keyB), .letter("b"))
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .keyM), .letter("m"))
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .keyR), .letter("r"))
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .keyJ), .letter("j"))
        XCTAssertEqual(GameControllerKeyboardSource.remoteKey(from: .keyK), .letter("k"))
        // Boundary letters.
        XCTAssertEqual(GameControllerKeyboardSource.letter(from: .keyA), "a")
        XCTAssertEqual(GameControllerKeyboardSource.letter(from: .keyZ), "z")
    }

    func testUnmappedKeycodeReturnsNil() {
        // A modifier / function key we don't bind.
        XCTAssertNil(GameControllerKeyboardSource.remoteKey(from: .leftShift))
        XCTAssertNil(GameControllerKeyboardSource.remoteKey(from: .F1))
    }

    // MARK: - handle(keyCode:) publishes bound events

    func testHandlePublishesBoundEvent() async {
        let store = makeStore()
        let bus = RemoteEventBus()
        let source = GameControllerKeyboardSource(bus: bus, store: store)

        // Default: arrowLeft → prevSection.
        var iterator = bus.events.makeAsyncIterator()
        source.handle(keyCode: .leftArrow)
        let event = await iterator.next()
        XCTAssertEqual(event, .prevSection)
    }

    func testHandleCapturesBeforeBindingGate() {
        let store = makeStore()
        // Clear the binding so the key is unmapped — capture must still fire.
        store.setBinding(nil, for: .letter("z"))
        var captured: [RemoteKey] = []
        let source = GameControllerKeyboardSource(
            bus: RemoteEventBus(),
            store: store,
            onCapture: { captured.append($0) }
        )
        source.handle(keyCode: .keyZ)
        XCTAssertEqual(captured, [.letter("z")],
                       "capture must run before the binding lookup so unmapped keys surface")
    }

    func testHandlePublishesDefaultKeypadSpeedEvents() async {
        let store = makeStore()
        let bus = RemoteEventBus()
        let source = GameControllerKeyboardSource(bus: bus, store: store)

        var iterator = bus.events.makeAsyncIterator()
        source.handle(keyCode: .keypadPlus)
        let up = await iterator.next()
        source.handle(keyCode: .keypadHyphen)
        let down = await iterator.next()

        XCTAssertEqual(up, .speedUp)
        XCTAssertEqual(down, .speedDown)
    }
}

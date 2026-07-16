//
//  GameControllerKeyboardSource.swift
//  OpenPrompter
//
//  Focus-independent keyboard remote source (Remote Input Audit fix 2 / R2).
//
//  ╭──────────────────────────── WHY THIS EXISTS ───────────────────────────╮
//  │ The original keyboard path is SwiftUI `.onKeyPress`, which fires only  │
//  │ while the prompter view holds first responder. A mounted phone can     │
//  │ silently lose focus (a sheet, a Picker, VoiceOver), and then arrow /   │
//  │ presenter keys go dead until the prompter is re-entered (audit B1).    │
//  │                                                                        │
//  │ `GCKeyboard.coalesced` delivers HID keyboard events GLOBALLY — no      │
//  │ first responder required. This source promotes the already-linked      │
//  │ GameController keyboard (used until now only for the status chip in    │
//  │ `KeyboardConnectionMonitor`) into a real `RemoteEventSource`. It maps  │
//  │ `GCKeyCode → RemoteKey`, looks the key up in the shared binding store, │
//  │ and publishes onto the same `RemoteEventBus` every other source feeds. │
//  │                                                                        │
//  │ `.onKeyPress` stays wired as a fallback (it catches presses that       │
//  │ arrive before GameController registers the keyboard on first connect). │
//  │ Both paths share the binding store, so a key never fires twice for the │
//  │ same physical press in practice — GameController owns delivery once    │
//  │ registered and `.onKeyPress` is gated on focus, which the mounted-      │
//  │ phone case has lost.                                                    │
//  ╰────────────────────────────────────────────────────────────────────────╯
//
//  Does NOT catch the AB-Shutter / BLE-M5 iOS-mode shutter (that's a
//  Consumer-Control volume button → `VolumeEventSource`) nor the BLE-M5
//  D-pad (pointer axes → `GCMouseSource`). Keyboard-class remotes only.
//

import Foundation
import GameController
import os

#if DEBUG
/// Shared `[Remote-Capture]` channel (see VolumeEventSource for rationale).
fileprivate let remoteCaptureLog = Logger(
    subsystem: "app.openprompter.remote",
    category: "Remote-Capture"
)
#endif

@MainActor
final class GameControllerKeyboardSource: RemoteEventSource {
    private let bus: RemoteEventBus
    private let store: RemoteBindingStore

    /// Optional tap invoked with the resolved `RemoteKey` for EVERY handled
    /// key-down, before the binding lookup — the Labs "learn my remote"
    /// capture tool subscribes here so unmapped keys still surface. `nil`
    /// in the normal prompter path. `@MainActor` because every caller and
    /// every subscriber (the capture log, the connection monitor) is.
    private let onCapture: (@MainActor (RemoteKey) -> Void)?

    private var started: Bool = false

    /// The keyboard we attached a handler to. Tracked so `stop()` clears the
    /// exact handler and a hot-plug (`GCKeyboardDidConnect`) can re-attach.
    private var attachedKeyboard: GCKeyboard?

    /// Observer tokens for connect / disconnect so a keyboard paired AFTER
    /// `start()` still gets a handler (the mounted-phone case: pair the
    /// remote once the prompter is already open).
    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?

    init(
        bus: RemoteEventBus,
        store: RemoteBindingStore,
        onCapture: (@MainActor (RemoteKey) -> Void)? = nil
    ) {
        self.bus = bus
        self.store = store
        self.onCapture = onCapture
    }

    func start() {
        guard !started else { return }
        started = true

        attachHandlerIfPossible()

        connectObserver = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.attachHandlerIfPossible() }
        }
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.detachHandler() }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        detachHandler()
        if let o = connectObserver { NotificationCenter.default.removeObserver(o) }
        if let o = disconnectObserver { NotificationCenter.default.removeObserver(o) }
        connectObserver = nil
        disconnectObserver = nil
    }

    /// True when this source has a live keyboard handler attached and is
    /// therefore delivering keys focus-free. The SwiftUI `.onKeyPress`
    /// FALLBACK reads this to stand down when GameController owns delivery,
    /// so a single physical keypress doesn't fire on BOTH paths at once.
    /// When no GC keyboard is registered yet (first-connect gap), this is
    /// false and the fallback takes over.
    var isDeliveringKeys: Bool {
        started && attachedKeyboard != nil
    }

    // MARK: - Handler attach / detach

    private func attachHandlerIfPossible() {
        guard let keyboard = GCKeyboard.coalesced?.keyboardInput else {
            #if DEBUG
            remoteCaptureLog.info("gckeyboard.attach — no coalesced keyboard present")
            #endif
            return
        }
        // If we're already attached to a live keyboard, don't double-wire.
        if attachedKeyboard != nil { return }
        attachedKeyboard = GCKeyboard.coalesced

        #if DEBUG
        remoteCaptureLog.info("gckeyboard.attach OK — keyChangedHandler wired")
        #endif

        keyboard.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            // Leading edge only — we act on key-DOWN, matching
            // `.onKeyPress(phases: .down)`. `pressed == false` is the release.
            guard pressed else { return }
            MainActor.assumeIsolated {
                self?.handle(keyCode: keyCode)
            }
        }
    }

    private func detachHandler() {
        attachedKeyboard?.keyboardInput?.keyChangedHandler = nil
        attachedKeyboard = nil
    }

    // MARK: - Mapping + dispatch

    /// Translate a `GCKeyCode` into a `RemoteKey`, record it for capture,
    /// look up the bound event, and publish. `internal` so unit tests can
    /// exercise the mapping + publish path without a live keyboard.
    func handle(keyCode: GCKeyCode) {
        guard let remoteKey = Self.remoteKey(from: keyCode) else {
            #if DEBUG
            remoteCaptureLog.info("gckeyboard.handle keycode=\(keyCode.rawValue, privacy: .public) → no RemoteKey mapping (dropped)")
            #endif
            return
        }
        #if DEBUG
        remoteCaptureLog.info("gckeyboard.handle key=\(remoteKey.id, privacy: .public) → onCapture hook=\(self.onCapture != nil, privacy: .public)")
        #endif
        onCapture?(remoteKey)
        guard let event = store.event(for: remoteKey) else { return }
        bus.publish(event)
    }

    /// `GCKeyCode → RemoteKey`. Covers the navigation keys the presenter
    /// remotes emit plus the letter keys we bind by default (b/m/r/j/k) and
    /// the full a–z range so remapping to any letter works. Unmapped
    /// keycodes (function keys, modifiers, punctuation) return `nil`.
    static func remoteKey(from code: GCKeyCode) -> RemoteKey? {
        switch code {
        case .spacebar:      return .space
        case .returnOrEnter, .keypadEnter: return .return
        case .escape:        return .escape
        case .tab:           return .tab
        case .upArrow:       return .arrowUp
        case .downArrow:     return .arrowDown
        case .leftArrow:     return .arrowLeft
        case .rightArrow:    return .arrowRight
        case .pageUp:        return .pageUp
        case .pageDown:      return .pageDown
        default:
            if let letter = Self.letter(from: code) {
                return .letter(letter)
            }
            return nil
        }
    }

    /// Map the a–z `GCKeyCode` block to a lowercase `Character`. GameController
    /// exposes each letter as its own `keyA … keyZ` case; we table them so the
    /// binding store's `.letter` keys resolve regardless of shift state.
    static func letter(from code: GCKeyCode) -> Character? {
        switch code {
        case .keyA: return "a"
        case .keyB: return "b"
        case .keyC: return "c"
        case .keyD: return "d"
        case .keyE: return "e"
        case .keyF: return "f"
        case .keyG: return "g"
        case .keyH: return "h"
        case .keyI: return "i"
        case .keyJ: return "j"
        case .keyK: return "k"
        case .keyL: return "l"
        case .keyM: return "m"
        case .keyN: return "n"
        case .keyO: return "o"
        case .keyP: return "p"
        case .keyQ: return "q"
        case .keyR: return "r"
        case .keyS: return "s"
        case .keyT: return "t"
        case .keyU: return "u"
        case .keyV: return "v"
        case .keyW: return "w"
        case .keyX: return "x"
        case .keyY: return "y"
        case .keyZ: return "z"
        default:    return nil
        }
    }
}

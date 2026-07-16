//
//  KeyboardConnectionMonitor.swift
//  OpenPrompter
//
//  Observes `GCKeyboard.coalescedKeyboard` + `GCMouse` plus their connect /
//  disconnect notifications so the Settings UI and prompter chip can show
//  an HONEST "remote detected" state (Remote Input Audit fix 5 / D5).
//
//  ╭──────────────────────────── FIX 5 — honest chip ───────────────────────╮
//  │ The chip used to reflect ONLY `GCKeyboard.coalesced`, so a working     │
//  │ Satechi R2 media remote or an AB-Shutter / BLE-M5 (which pair as a     │
//  │ media/volume device or a pointer, NOT a keyboard) showed "no keyboard  │
//  │ detected" while driving the prompter fine. This monitor now ALSO       │
//  │ watches `GCMouse` presence AND — the load-bearing part — flips a       │
//  │ `hasSeenRemoteEvent` flag the FIRST time ANY source (keyboard / mouse  │
//  │ / media / volume) publishes an event. Once we've actually seen input,  │
//  │ "remote detected" is truthful regardless of HID class.                 │
//  ╰────────────────────────────────────────────────────────────────────────╯
//
//  This is a status indicator only — it does NOT drive event delivery.
//  Keyboard delivery is `GameControllerKeyboardSource` (focus-independent)
//  with SwiftUI `.onKeyPress` as a fallback; pointer delivery is
//  `GCMouseSource`; media / volume have their own sources.
//
//  Soft-coupled to GameController via `import GameController` — the cost is
//  small and it's the only system API for keyboard / mouse presence.
//

import Foundation
import GameController
import Observation

@Observable
@MainActor
final class KeyboardConnectionMonitor {
    /// True when a HID keyboard is coalesced (Magic Keyboard, presenter
    /// clicker that pairs as a keyboard, etc.).
    private(set) var isKeyboardConnected: Bool = false

    /// True when a pointer / mouse-class device is attached (the founder's
    /// BLE-M5 D-pad pairs as a trackpad — BLE-M5 Capture.md).
    private(set) var isMouseConnected: Bool = false

    /// Latched the first time ANY remote source publishes an event. Once set
    /// it stays set for the monitor's lifetime — "we have proof this user's
    /// remote reaches the app." Reset only by re-instantiating the monitor.
    private(set) var hasSeenRemoteEvent: Bool = false

    /// The single source of truth the chip should read.
    ///
    /// ╭─────────────── FIX (v3.1) — event latch OR pointer presence ────────╮
    /// │ v3 narrowed this to `hasSeenRemoteEvent` ALONE to kill a stale      │
    /// │ keyboard false-positive (`GCKeyboard.coalesced` reports a keyboard  │
    /// │ for transient / accessibility / stale HID peers with nothing        │
    /// │ paired). That over-corrected: on the SETTINGS screen NO source is   │
    /// │ running to emit an event, so a genuinely-connected remote could     │
    /// │ NEVER latch the chip there — it read "no remote detected" with the  │
    /// │ remote plugged in. That is the founder's exact complaint.           │
    /// │                                                                     │
    /// │ The founder's BLE-M5 D-pad pairs as a Bluetooth TRACKPAD, not a     │
    /// │ keyboard (BLE-M5 Capture.md), so `GCMouse` PRESENCE is the only     │
    /// │ at-rest signal that its remote is connected. GCMouse presence is    │
    /// │ reliable (iOS surfaces it only for a real pointing device), so we   │
    /// │ OR it back in. Keyboard PRESENCE stays OUT — that was the flaky     │
    /// │ signal — but a real keyboard remote still latches the chip on its   │
    /// │ FIRST event via `hasSeenRemoteEvent`, as do media / volume remotes  │
    /// │ that present as neither keyboard nor mouse.                         │
    /// ╰─────────────────────────────────────────────────────────────────────╯
    var isRemoteDetected: Bool {
        hasSeenRemoteEvent || isMouseConnected
    }

    /// Call from any source the FIRST time it publishes an event (or on
    /// every event — it's idempotent once latched). Makes the chip honest
    /// for remotes that don't register as a keyboard or mouse.
    func noteRemoteEvent() {
        guard !hasSeenRemoteEvent else { return }
        hasSeenRemoteEvent = true
    }

    /// Force a fresh read of GameController keyboard / mouse presence. The
    /// connect / disconnect notifications keep the flags current in the steady
    /// state; a view that appears (the Settings chip, the "learn my remote"
    /// diagnostics) calls this so its on-screen readout reflects a device that
    /// was already paired before the view — without waiting for the next
    /// notification. Cheap and idempotent.
    func refreshConnectedDevices() {
        refresh()
    }

    // `nonisolated(unsafe)` because `deinit` is implicitly nonisolated and
    // needs to read these tokens to remove the observers. Each token is
    // assigned exactly once in `init()` (on the main actor) and never
    // mutated afterwards, so there is no actual race for the compiler check
    // to protect against. The annotation is the safe-by-construction
    // declaration; we don't reach for `@unchecked Sendable` on the class.
    @ObservationIgnored
    private nonisolated(unsafe) var connectObserver: NSObjectProtocol?
    @ObservationIgnored
    private nonisolated(unsafe) var disconnectObserver: NSObjectProtocol?
    @ObservationIgnored
    private nonisolated(unsafe) var mouseConnectObserver: NSObjectProtocol?
    @ObservationIgnored
    private nonisolated(unsafe) var mouseDisconnectObserver: NSObjectProtocol?

    init() {
        refresh()
        connectObserver = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        mouseConnectObserver = NotificationCenter.default.addObserver(
            forName: .GCMouseDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        mouseDisconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCMouseDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // Teardown on dealloc. Even though this monitor is currently app-scoped
    // (via AppState), tests and any future re-instantiation paths require
    // explicit observer removal — leaving an observer registered retains
    // the monitor and produces phantom callbacks the next time the same
    // notification fires.
    //
    // `deinit` is implicitly nonisolated. We capture the tokens locally
    // (so we don't reach for self's main-actor state from the nonisolated
    // context) and hop to `@MainActor` for the actual removal. The hop is
    // fire-and-forget, which is safe for cleanup work.
    deinit {
        let connect = connectObserver
        let disconnect = disconnectObserver
        let mouseConnect = mouseConnectObserver
        let mouseDisconnect = mouseDisconnectObserver
        Task { @MainActor in
            if let connect         { NotificationCenter.default.removeObserver(connect) }
            if let disconnect      { NotificationCenter.default.removeObserver(disconnect) }
            if let mouseConnect    { NotificationCenter.default.removeObserver(mouseConnect) }
            if let mouseDisconnect { NotificationCenter.default.removeObserver(mouseDisconnect) }
        }
    }

    private func refresh() {
        isKeyboardConnected = GCKeyboard.coalesced != nil
        isMouseConnected = GCMouse.current != nil || !GCMouse.mice().isEmpty
    }
}

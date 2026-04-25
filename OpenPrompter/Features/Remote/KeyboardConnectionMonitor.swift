//
//  KeyboardConnectionMonitor.swift
//  OpenPrompter
//
//  Observes `GCKeyboard.coalescedKeyboard` plus the
//  `GCKeyboardDidConnect` / `GCKeyboardDidDisconnect` notifications so the
//  Settings UI and prompter chip can show "Bluetooth keyboard connected".
//
//  This is a status indicator only — it does NOT drive event delivery.
//  The keyboard event source itself relies on SwiftUI `.onKeyPress`, which
//  works regardless of whether GameController has registered a keyboard
//  yet (e.g. on first connect, before GameController catches up).
//
//  Soft-coupled to GameController via `import GameController` — the cost is
//  small and it's the only system API for keyboard presence detection.
//

import Foundation
import GameController
import Observation

@Observable
@MainActor
final class KeyboardConnectionMonitor {
    private(set) var isKeyboardConnected: Bool = false

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
        Task { @MainActor in
            if let connect    { NotificationCenter.default.removeObserver(connect) }
            if let disconnect { NotificationCenter.default.removeObserver(disconnect) }
        }
    }

    private func refresh() {
        isKeyboardConnected = GCKeyboard.coalesced != nil
    }
}

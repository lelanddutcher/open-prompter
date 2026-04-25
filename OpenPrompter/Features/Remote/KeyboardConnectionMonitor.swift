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

    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?

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

    // We deliberately omit a deinit observer-removal block. The monitor is
    // app-scoped (lives on AppState) and never deallocates during a normal
    // run; reaching for the main-actor isolated observer tokens from a
    // nonisolated `deinit` runs into Swift 6 isolation rules. NSNotification
    // observers without explicit removal are released when the object is
    // freed at process exit, which is the only path that gets here.

    private func refresh() {
        isKeyboardConnected = GCKeyboard.coalesced != nil
    }
}

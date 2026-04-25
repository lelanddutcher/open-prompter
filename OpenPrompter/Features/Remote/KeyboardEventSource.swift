//
//  KeyboardEventSource.swift
//  OpenPrompter
//
//  Bridges SwiftUI `.onKeyPress` (iOS 17+) into the `RemoteEventBus`.
//  This file ships two pieces:
//
//  1. `KeyboardEventSource` — a tiny stateful wrapper that holds the bus +
//     binding store and exposes `handle(_:)` so a SwiftUI view can call it
//     from `.onKeyPress`. Conforms to `RemoteEventSource` for symmetry with
//     the other sources, even though there's no continuous observation to
//     start/stop — focus management lives in the view.
//
//  2. `View.bindRemoteKeyboard(_:)` — a small modifier that wires
//     `.focusable()`, `.focused()`, and `.onKeyPress(...)` onto a host view.
//     The view is responsible for setting `isFocused = true` when it appears
//     and `false` when it leaves; without this, `.onKeyPress` will not fire.
//
//  Gotcha — VoiceOver:
//      VoiceOver intercepts arrow keys (and many other keys) before SwiftUI
//      sees them. With VO on, the user gets the screen-reader semantics, not
//      our prompter shortcuts. This is an iOS-level behavior, not something
//      we can override. We document it in the in-Settings copy.
//

import SwiftUI

@MainActor
final class KeyboardEventSource: RemoteEventSource {
    private let bus: RemoteEventBus
    private let store: RemoteBindingStore

    init(bus: RemoteEventBus, store: RemoteBindingStore) {
        self.bus = bus
        self.store = store
    }

    func start() { /* No-op — focus owns lifetime. */ }
    func stop()  { /* No-op — focus owns lifetime. */ }

    /// Translate a SwiftUI `KeyPress` into a `RemoteKey`, look it up in the
    /// store, and publish the resulting event. Returns `.handled` if we
    /// emitted, `.ignored` otherwise — so SwiftUI can fall back to default
    /// behavior for keys we don't bind.
    func handle(_ press: KeyPress) -> KeyPress.Result {
        guard let remoteKey = Self.remoteKey(from: press) else { return .ignored }
        guard let event = store.event(for: remoteKey) else { return .ignored }
        bus.publish(event)
        return .handled
    }

    /// SwiftUI's `KeyPress.key` is a `KeyEquatable`; we translate the
    /// well-known cases into our `RemoteKey` enum. Letter keys come through
    /// as ".character('b')". We lowercase so the binding doesn't depend on
    /// shift state.
    static func remoteKey(from press: KeyPress) -> RemoteKey? {
        switch press.key {
        case .space:      return .space
        case .return:     return .return
        case .escape:     return .escape
        case .tab:        return .tab
        case .upArrow:    return .arrowUp
        case .downArrow:  return .arrowDown
        case .leftArrow:  return .arrowLeft
        case .rightArrow: return .arrowRight
        case .pageUp:     return .pageUp
        case .pageDown:   return .pageDown
        default:
            // Single-character keys come through `press.characters`.
            let chars = press.characters.lowercased()
            if let c = chars.first, chars.count == 1, c.isLetter {
                return .letter(c)
            }
            return nil
        }
    }
}

// MARK: - SwiftUI focus glue

extension View {
    /// Wires keyboard focus + `.onKeyPress` onto the receiver. Caller passes
    /// a `FocusState` binding so it controls when the view should "own" the
    /// keyboard (e.g. while the prompter is the visible scene). The handler
    /// translates each key into a `RemoteEvent` via the source.
    ///
    /// `.allowedCharacters(.alphanumerics)` would limit which keys reach us,
    /// but we want full symbol coverage for navigation keys, so we use the
    /// no-argument `.onKeyPress` form.
    @ViewBuilder
    func bindRemoteKeyboard(
        source: KeyboardEventSource,
        isFocused: FocusState<Bool>.Binding
    ) -> some View {
        self
            .focusable()
            .focused(isFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in
                source.handle(press)
            }
    }
}

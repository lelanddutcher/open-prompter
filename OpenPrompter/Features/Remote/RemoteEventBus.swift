//
//  RemoteEventBus.swift
//  OpenPrompter
//
//  Single fan-in pipe for all remote event sources. Sources push events via
//  `publish(_:)`; the prompter view subscribes to `events` (an AsyncStream).
//
//  Synchronization audit:
//  – `AsyncStream.Continuation.yield(_:)` is documented thread-safe across
//    arbitrary contexts, so `publish(_:)` needs no actor isolation or lock
//    to be correct. The class holds only `let` properties of `Sendable`
//    types, which is enough for plain `Sendable` conformance — no
//    `@unchecked` escape hatch, no false advertising about actor semantics.
//  – KVO-driven sources (`VolumeEventSource`) hop to `@MainActor` before
//    publishing because their handlers also touch view-layer state.
//    `MediaCommandSource` and `KeyboardEventSource` are `@MainActor`
//    already. Future non-main-actor sources can call `publish(_:)`
//    directly — the underlying primitive is thread-safe.
//
//  Cancellation: `events` keeps yielding for the bus's lifetime. Each consumer
//  cancels its own iteration when its parent task is cancelled. The bus is
//  per-prompter-session so there's no need to finish the continuation
//  explicitly — it dies with the view model.
//

import Foundation

/// Abstraction for any remote event producer. Sources hold a reference to the
/// shared bus and push events when their underlying input fires. They are
/// responsible for their own lifecycle (start / stop) and for honoring user
/// settings (e.g. `VolumeEventSource` is opt-in only).
///
/// `@MainActor` because every concrete source runs against UIKit / SwiftUI
/// state — focus, MediaPlayer command center, AVAudioSession — and forcing
/// the protocol onto the main actor matches the implementation reality
/// without nonisolated bridging boilerplate.
@MainActor
protocol RemoteEventSource: AnyObject {
    /// Start observing the underlying input. Idempotent.
    func start()
    /// Stop observing. Idempotent.
    func stop()
}

/// Thread-safe pub/sub for `RemoteEvent`. One bus per prompter session.
/// `Sendable` conformance is genuine: every stored property is `let` and
/// of a `Sendable` type, with thread-safety provided by
/// `AsyncStream.Continuation.yield(_:)`. No `@unchecked` required.
final class RemoteEventBus: Sendable {
    /// AsyncStream of every event ever published. Late subscribers miss
    /// earlier events — this is intentional. Remote events are transient
    /// inputs, not persistent state.
    let events: AsyncStream<RemoteEvent>
    private let continuation: AsyncStream<RemoteEvent>.Continuation

    init() {
        var continuation: AsyncStream<RemoteEvent>.Continuation!
        self.events = AsyncStream { c in continuation = c }
        self.continuation = continuation
    }

    /// Publish an event. Safe to call from any thread / actor context.
    func publish(_ event: RemoteEvent) {
        continuation.yield(event)
    }
}

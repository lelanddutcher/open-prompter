//
//  RemoteEventBus.swift
//  OpenPrompter
//
//  Single fan-in pipe for all remote event sources. Sources push events via
//  `publish(_:)`; the prompter view subscribes to `events` (an AsyncStream).
//
//  Why an actor wrapping an `AsyncStream.Continuation`:
//  – Multiple sources can call `publish` from arbitrary threads (KVO from
//    AVAudioSession runs on a private queue, MPRemoteCommandCenter on the
//    main queue, `.onKeyPress` on main). The actor serialises pushes.
//  – Consumer side is a single `for await` loop in the view layer, which
//    keeps the view model code simple and Swift-Concurrency-clean.
//
//  Cancellation: `events` keeps yielding for the bus's lifetime. Each consumer
//  cancels its own iteration when its parent task is cancelled. The bus is
//  long-lived (one per app launch) so there's no need to finish the
//  continuation explicitly.
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

/// Thread-safe pub/sub for `RemoteEvent`. One bus per app session.
final class RemoteEventBus: @unchecked Sendable {
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

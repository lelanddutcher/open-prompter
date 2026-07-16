//
//  MockScriptFormatter.swift
//  OpenPrompter
//
//  Test / preview double for `ScriptFormatting`. Yields a scripted sequence
//  of cumulative snapshots (or throws a scripted error) with NO OS
//  dependency, so the whole confirm / undo / persistence flow is testable on
//  CI simulators that lack Apple Intelligence. Records the calls it received
//  so tests can assert "the formatter was never invoked" for the length
//  pre-flight case.
//
//  Compiled into the app target (not #if DEBUG) so SwiftUI previews and the
//  ScriptFormatterFactory test seam can reach it; it imports no
//  FoundationModels and holds no model state.
//

import Foundation

/// Deterministic mock formatter. Configure `snapshots` (cumulative, in
/// order) for the happy path, or `errorToThrow` to exercise a failure. When
/// `errorToThrow` is set it is thrown after emitting any snapshots queued
/// before it, matching how a real stream can partially deliver then fail.
final class MockScriptFormatter: ScriptFormatting, @unchecked Sendable {
    /// Reported availability. Defaults to `.available` so flow tests don't
    /// have to override it.
    let availabilityValue: FormatAvailability

    /// Cumulative snapshots to yield, in order. The last one is the "final"
    /// formatted text.
    let snapshots: [String]

    /// If set, thrown after the snapshots are yielded (simulates a mid- or
    /// post-stream failure). `nil` => the stream finishes cleanly.
    let errorToThrow: Error?

    /// Per-snapshot delay so cancellation tests have a window to cancel in.
    /// Zero by default for fast, deterministic happy-path tests.
    let perSnapshotDelay: Duration

    /// Every (source, prompt) pair the formatter was asked to stream. Lets a
    /// test assert the length pre-flight refused BEFORE any call.
    private(set) var receivedCalls: [(source: String, prompt: String)] = []

    /// Serializes access to `receivedCalls` across the stream's Task.
    private let lock = NSLock()

    init(
        availability: FormatAvailability = .available,
        snapshots: [String] = [],
        errorToThrow: Error? = nil,
        perSnapshotDelay: Duration = .zero
    ) {
        self.availabilityValue = availability
        self.snapshots = snapshots
        self.errorToThrow = errorToThrow
        self.perSnapshotDelay = perSnapshotDelay
    }

    var availability: FormatAvailability { availabilityValue }

    /// Number of times `formatStream` was invoked. Read from tests.
    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return receivedCalls.count
    }

    func formatStream(source: String, prompt: String)
        -> AsyncThrowingStream<String, Error>
    {
        lock.lock()
        receivedCalls.append((source: source, prompt: prompt))
        lock.unlock()

        let snapshots = self.snapshots
        let errorToThrow = self.errorToThrow
        let delay = self.perSnapshotDelay

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for snapshot in snapshots {
                        try Task.checkCancellation()
                        if delay != .zero {
                            try await Task.sleep(for: delay)
                        }
                        continuation.yield(snapshot)
                    }
                    if let errorToThrow {
                        continuation.finish(throwing: errorToThrow)
                    } else {
                        continuation.finish()
                    }
                } catch is CancellationError {
                    continuation.finish(throwing: FormatError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

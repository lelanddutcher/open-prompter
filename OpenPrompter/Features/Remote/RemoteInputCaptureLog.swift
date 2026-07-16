//
//  RemoteInputCaptureLog.swift
//  OpenPrompter
//
//  "Learn my remote" capture log (Remote Input Audit fix 3 / §5). DEBUG only.
//
//  ╭──────────────────────────── WHAT THIS IS ──────────────────────────────╮
//  │ The in-app analog of the macOS `hidcap.swift` HID logger that          │
//  │ characterized the founder's BLE-M5 (BLE-M5 Capture.md). The founder    │
//  │ pairs any BLE clicker and SEES exactly what it emits — which source    │
//  │ fired (keyboard / mouse / media / volume), the resolved `RemoteKey`    │
//  │ (or `nil` if the app has no key for it yet), and the currently-bound   │
//  │ event. Read-only diagnostic: entries are recorded live and can be      │
//  │ exported to `Documents/RemoteCapture.json` for a devicectl pull, the   │
//  │ same pattern as the recording self-test.                               │
//  ╰────────────────────────────────────────────────────────────────────────╯
//
//  Capture happens BEFORE the binding gate in each source (via the source's
//  `onCapture` hook), so an unmapped device still shows up — the whole point
//  is to discover what an unknown remote emits so it becomes bindable.
//

#if DEBUG

import Foundation
import Observation

/// One captured remote input event, machine-readable so it round-trips
/// through `Codable` for the JSON export / test-fixture flow.
struct CapturedRemoteInput: Codable, Identifiable, Equatable {
    /// Wall-clock capture time.
    let timestamp: Date
    /// Which source produced it: `"keyboard"`, `"mouse"`, `"media"`, `"volume"`.
    let source: String
    /// Free-form descriptor of the raw input (e.g. the `RemoteKey.id`, a
    /// scroll direction, or a volume delta). Human-readable in the log list.
    let rawDescriptor: String
    /// The resolved `RemoteKey.id`, or `nil` when the source produced input
    /// the app has no `RemoteKey` for (proves capture happens before the
    /// binding gate).
    let resolvedRemoteKey: String?
    /// The `RemoteEvent.rawValue` currently bound to that key, or `nil` when
    /// the key is unbound.
    let boundEvent: String?

    /// Stable identity for `ForEach`. Timestamp + descriptor is unique enough
    /// for a live-scrolling diagnostic list.
    var id: String { "\(timestamp.timeIntervalSince1970)-\(rawDescriptor)" }
}

/// Live, capped, observable log of captured remote inputs. `@MainActor`
/// because every source that feeds it already runs on the main actor and the
/// SwiftUI list reads it directly.
@Observable
@MainActor
final class RemoteInputCaptureLog {
    /// Newest-first list of captured inputs. Capped so a stuck remote
    /// (auto-repeat) can't grow it without bound.
    private(set) var entries: [CapturedRemoteInput] = []

    /// Max retained entries; oldest are dropped past this. ~200 matches the
    /// self-test harness's cap and is plenty for characterizing a remote.
    static let maxEntries = 200

    /// Append a captured input, trimming to the cap. Newest at index 0 so the
    /// live list shows the most recent press at the top without a reverse.
    func record(_ input: CapturedRemoteInput) {
        entries.insert(input, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
    }

    /// Convenience: build + record a keyboard / mouse-button entry from a
    /// resolved `RemoteKey`, resolving its bound event through the store.
    func recordKey(_ key: RemoteKey, source: String, store: RemoteBindingStore, now: Date = Date()) {
        let event = store.event(for: key)
        record(CapturedRemoteInput(
            timestamp: now,
            source: source,
            rawDescriptor: key.displayName,
            resolvedRemoteKey: key.id,
            boundEvent: event?.rawValue
        ))
    }

    /// Convenience: record a source-level event that has NO bindable key
    /// (pointer scroll travel, a media command that resolved straight to an
    /// event). `rawDescriptor` describes the physical input.
    func recordEvent(_ event: RemoteEvent, source: String, rawDescriptor: String, now: Date = Date()) {
        record(CapturedRemoteInput(
            timestamp: now,
            source: source,
            rawDescriptor: rawDescriptor,
            resolvedRemoteKey: nil,
            boundEvent: event.rawValue
        ))
    }

    /// Clear the log (the "clear" button in the Labs view).
    func clear() {
        entries.removeAll()
    }

    /// Serialize the current log to JSON. Used by the "export" button; writes
    /// `Documents/RemoteCapture.json` for a devicectl pull. Returns the file
    /// URL on success, or nil if the encode / write failed.
    @discardableResult
    func exportJSON() -> URL? {
        guard let data = try? JSONEncoder.remoteCaptureEncoder.encode(entries) else { return nil }
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteCapture.json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

private extension JSONEncoder {
    /// Pretty, sorted, ISO-8601 dates — a readable fixture the founder can
    /// diff or hand back as a test input.
    static var remoteCaptureEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

#endif

//
//  ICloudWatcher.swift
//  OpenPrompter
//
//  NSMetadataQuery wrapper that discovers .md files inside a user-picked
//  iCloud Drive folder and publishes change events when iCloud finishes
//  syncing edits made on another device (Mac Obsidian save -> iPhone
//  update).
//
//  Key insight: NSMetadataQuery scoped to NSMetadataQueryUbiquitousDocumentsScope
//  fires .NSMetadataQueryDidUpdate when iCloud pushes a new version. Latency
//  is typically 2-8s on good wifi but can reach 30s. Document honestly in UI.
//

import Foundation
import Observation

@Observable
@MainActor
final class ICloudWatcher {
    // MARK: - Public state

    private(set) var files: [ScriptFile] = []
    private(set) var isRunning: Bool = false
    private(set) var lastUpdateAt: Date?

    /// Stream of per-file change events. UI can subscribe to know when a
    /// specific open file has been modified on another device.
    let changed: AsyncStream<URL>
    private let changedContinuation: AsyncStream<URL>.Continuation

    // MARK: - Private state

    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private var scopeURL: URL?
    private var knownMtimes: [URL: Date] = [:]

    // MARK: - Init

    init() {
        var continuation: AsyncStream<URL>.Continuation!
        self.changed = AsyncStream { continuation = $0 }
        self.changedContinuation = continuation
    }

    deinit {
        changedContinuation.finish()
    }

    // MARK: - Lifecycle

    func start(scope: URL) {
        stop()
        scopeURL = scope

        // Pin all query callbacks to the main queue so disableUpdates/enableUpdates
        // pairing and `query.results` reads are trivially race-free.
        query.operationQueue = OperationQueue.main
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(
            format: "%K LIKE[c] '*.md' OR %K LIKE[c] '*.markdown'",
            NSMetadataItemFSNameKey,
            NSMetadataItemFSNameKey
        )
        query.sortDescriptors = [
            NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)
        ]

        // Observers registered with queue: .main run synchronously on the main thread.
        // Since ICloudWatcher is @MainActor, we can call consumeResults() directly.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: query,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.consumeResults() }
            },
            center.addObserver(
                forName: .NSMetadataQueryDidUpdate,
                object: query,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.consumeResults() }
            }
        ]

        query.start()
        isRunning = true
    }

    func stop() {
        if query.isStarted { query.stop() }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        isRunning = false
        scopeURL = nil
        knownMtimes.removeAll()
        files.removeAll()
    }

    // MARK: - Private

    private func consumeResults() {
        query.disableUpdates()
        defer { query.enableUpdates() }

        var out: [ScriptFile] = []
        var newMtimes: [URL: Date] = [:]

        // Build a normalized scope prefix that's trailing-slashed to avoid
        // false positives (e.g., /foo/Obsidian matching /foo/ObsidianArchive).
        let scopePrefix: String? = scopeURL.map { url in
            let path = url.standardized.path
            return path.hasSuffix("/") ? path : path + "/"
        }

        for case let item as NSMetadataItem in query.results {
            guard
                let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                let name = item.value(forAttribute: NSMetadataItemFSNameKey) as? String,
                let mtime = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
            else { continue }

            // Filter to the user-selected scope.
            if let prefix = scopePrefix {
                let stdPath = url.standardized.path
                if !stdPath.hasPrefix(prefix) { continue }
            }

            let rawStatus = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            let state = ScriptFile.DownloadState(rawValue: rawStatus ?? "") ?? .current

            // Kick off download for anything that isn't local. Call is idempotent.
            if state == .notDownloaded {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                // Skip from the visible list until the local copy is ready —
                // attempting to read it will block or return placeholder bytes.
                continue
            }

            let file = ScriptFile(id: url, name: name, mtime: mtime, downloadState: state)
            out.append(file)
            newMtimes[url] = mtime

            // Emit a change event if mtime advanced since we last saw this file.
            if let previous = knownMtimes[url], previous < mtime {
                changedContinuation.yield(url)
            }
        }

        self.files = out.sorted { $0.mtime > $1.mtime }
        self.knownMtimes = newMtimes
        self.lastUpdateAt = Date()
    }
}

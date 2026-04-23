//
//  ICloudWatcher.swift
//  OpenPrompter
//
//  Folder watcher. Scans the user-picked security-scoped folder directly
//  via FileManager, filters to .md / .markdown, and watches the folder
//  with a DispatchSource for add / rename / delete events. iCloud sync is
//  also covered because the OS surfaces synced file changes as regular
//  directory events on the ubiquitous path.
//
//  Name kept for import compatibility even though the implementation is
//  no longer iCloud-specific — it works for iCloud Drive, On My iPhone,
//  Obsidian vaults, Dropbox, any provider Files app can reach.
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
    private(set) var scopeURL: URL?

    /// Stream of per-file change events. UI can subscribe to know when a
    /// specific open file has been modified.
    let changed: AsyncStream<URL>
    private let changedContinuation: AsyncStream<URL>.Continuation

    // MARK: - Private state

    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFD: CInt = -1
    private var knownMtimes: [URL: Date] = [:]
    /// A lightweight polling task keeps iCloud-pulled edits visible even
    /// when DispatchSource misses them (network-side changes don't always
    /// reach the local inode watcher — iOS deposits the file via a
    /// coordinated write outside our descriptor).
    private var pollTask: Task<Void, Never>?

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
        isRunning = true

        // Initial scan — populate synchronously so the Library shows files
        // on the first render after the user picks a folder.
        rescan()

        // Open a file descriptor on the folder and listen for inode events.
        // This fires for adds / deletes / renames / attribute changes.
        let fd = open(scope.path, O_EVTONLY)
        if fd >= 0 {
            dirFD = fd
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename, .attrib, .extend],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.rescan() }
            }
            source.setCancelHandler { [weak self] in
                guard let self else { return }
                if self.dirFD >= 0 {
                    close(self.dirFD)
                    self.dirFD = -1
                }
            }
            dirSource = source
            source.resume()
        }

        // Safety net: poll every 10s so cloud-pulled edits that don't
        // register as local inode events still show up quickly.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                await MainActor.run { self?.rescan() }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        dirSource?.cancel()
        dirSource = nil
        if dirFD >= 0 {
            close(dirFD)
            dirFD = -1
        }
        isRunning = false
        scopeURL = nil
        knownMtimes.removeAll()
        files.removeAll()
        lastUpdateAt = nil
    }

    // MARK: - Public API

    /// Force a re-scan. Called from pull-to-refresh and after file writes.
    func refresh() {
        rescan()
    }

    /// Display name for the currently-watched folder. Used by the Library
    /// header so the user can see which folder they picked.
    var folderDisplayName: String? {
        scopeURL?.lastPathComponent
    }

    /// Rough iOS-style display path for the watched folder, trimmed for
    /// on-screen header usage (no system container cruft).
    var folderDisplayPath: String? {
        guard let url = scopeURL else { return nil }
        let path = url.standardized.path
        // Strip the iOS data container prefix so we show a user-friendly path.
        if let range = path.range(of: "/Mobile Documents/") {
            let rest = path[range.upperBound...]
            // Drop the "iCloud~md~obsidian~vault/" container prefix where present.
            if let slash = rest.firstIndex(of: "/") {
                return "iCloud/" + rest[rest.index(after: slash)...]
            }
            return "iCloud/" + String(rest)
        }
        if path.contains("/com~apple~CloudDocs/") {
            if let r = path.range(of: "/com~apple~CloudDocs/") {
                return "iCloud Drive/" + path[r.upperBound...]
            }
        }
        if path.contains("/File Provider Storage/") {
            return url.lastPathComponent
        }
        return path
    }

    // MARK: - Private

    private func rescan() {
        guard let scope = scopeURL else { return }

        let keys: [URLResourceKey] = [
            .contentModificationDateKey,
            .isDirectoryKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]

        let enumerator = (try? FileManager.default.contentsOfDirectory(
            at: scope,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        var out: [ScriptFile] = []
        var newMtimes: [URL: Date] = [:]

        for url in enumerator {
            let ext = url.pathExtension.lowercased()
            guard ext == "md" || ext == "markdown" else { continue }

            // Skip directories that happen to end with .md (rare but possible).
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true { continue }

            let mtime = values?.contentModificationDate ?? .distantPast
            let state = downloadState(for: values)

            // Kick off download for anything that isn't local yet.
            if state == .notDownloaded {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                continue
            }

            let file = ScriptFile(
                id: url,
                name: url.lastPathComponent,
                mtime: mtime,
                downloadState: state
            )
            out.append(file)
            newMtimes[url] = mtime

            if let previous = knownMtimes[url], previous < mtime {
                changedContinuation.yield(url)
            }
        }

        self.files = out.sorted { $0.mtime > $1.mtime }
        self.knownMtimes = newMtimes
        self.lastUpdateAt = Date()
    }

    private func downloadState(for values: URLResourceValues?) -> ScriptFile.DownloadState {
        guard let values else { return .current }

        // Non-ubiquitous files are always local.
        if values.isUbiquitousItem != true { return .downloaded }

        switch values.ubiquitousItemDownloadingStatus {
        case .some(.current):     return .current
        case .some(.downloaded):  return .downloaded
        case .some(.notDownloaded): return .notDownloaded
        default: return .current
        }
    }
}

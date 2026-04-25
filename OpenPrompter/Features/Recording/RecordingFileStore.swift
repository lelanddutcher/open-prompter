//
//  RecordingFileStore.swift
//  OpenPrompter
//
//  Disk paths for in-progress and finalized takes. Centralized here so the
//  recording session, the recovery scan, and tests use a single source of
//  truth for `Documents/Recordings/`.
//

import Foundation

enum RecordingFileStore {

    /// Sandbox directory holding takes. Created on first use.
    static var directory: URL {
        let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("Recordings", isDirectory: true)
    }

    /// Make sure the directory exists. Throws on disk-pressure failures so
    /// the caller can surface an error banner.
    @discardableResult
    static func ensureDirectory() throws -> URL {
        let dir = directory
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Build a unique filename for a new take. The ISO timestamp doubles as
    /// a tie-breaker on rapid back-to-back recordings (the user can't tap
    /// REC twice within one second, but if they did, the seconds component
    /// would still differ).
    static func newRecordingURL(now: Date = .now) -> URL {
        let stamp = ISO8601DateFormatter.fileSafe
            .string(from: now)
            .replacingOccurrences(of: ":", with: "")
        return directory.appendingPathComponent("\(stamp).mov")
    }

    /// Scan for `.mov` files left behind by an interrupted recording. Used
    /// by the launch-time recovery flow — if any `.mov` is sitting in the
    /// directory at app launch, the previous run was force-quit mid-take
    /// (we delete on successful save) and we surface a "Recover / Discard"
    /// banner.
    ///
    /// Returns the most recent stale file by modification date, or `nil` if
    /// the directory is empty / missing.
    static func mostRecentStaleRecording() -> URL? {
        let fm = FileManager.default
        let dir = directory
        guard let contents = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let movies = contents.filter { $0.pathExtension.lowercased() == "mov" }
        return movies
            .map { url -> (URL, Date) in
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return (url, mtime)
            }
            .max(by: { $0.1 < $1.1 })?
            .0
    }

    /// Remove every stale `.mov` (called from the "Discard" banner action).
    static func discardAllStaleRecordings() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in contents where url.pathExtension.lowercased() == "mov" {
            try? fm.removeItem(at: url)
        }
    }

    /// Remove a single file. The session calls this after a successful Photos
    /// write so the recovery scan only finds genuinely-interrupted takes.
    static func removeRecording(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

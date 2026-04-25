//
//  ICloudCopyJob.swift
//  OpenPrompter
//
//  Copies the finalized .mov from the app sandbox into the script's parent
//  folder. The copy is performed inside an `NSFileCoordinator` block so the
//  iCloud sync layer doesn't fight us; the Files app then handles uploading
//  to iCloud whatever lives at the destination.
//
//  Failure is surfaced IMMEDIATELY (no retry queue, no parked files) per
//  V2 Design 02 review note 4. The user's stance: "tell me right away if
//  the copy didn't happen — Files handles iCloud upload from there."
//

import Foundation

enum ICloudCopyJob {

    /// One-shot copy. Runs on a detached task so multi-hundred-MB files
    /// don't freeze the calling actor (in production: MainActor via
    /// `RecordingSession.runSaveFlow`). Returns a `Result` once the
    /// `NSFileCoordinator.coordinate` block plus the underlying
    /// `FileManager.copyItem` complete.
    ///
    /// `script` is the script being read at the start of the take. The copy
    /// lands at `<script-parent>/<script-stem>__<ISO-timestamp>.mov`. If the
    /// script lives outside iCloud (a local-only folder picked via
    /// `FolderPickerView`), the copy still proceeds — the destination is
    /// the script's actual parent directory regardless.
    ///
    /// `recording` is the absolute URL of the finalized take in
    /// `Documents/Recordings/`. We never delete the source — Photos already
    /// has a copy and the recovery flow may want to read this file later.
    static func copy(
        recording: URL,
        forScript script: URL,
        timestamp: Date = .now
    ) async -> Result<URL, ICloudCopyError> {
        await Task.detached(priority: .userInitiated) {
            performCopy(recording: recording, forScript: script, timestamp: timestamp)
        }.value
    }

    /// Synchronous body of the copy. Lives on the detached task so
    /// `NSFileCoordinator.coordinate` (synchronous) and the
    /// `FileManager.copyItem` byte pump don't block the caller.
    private static func performCopy(
        recording: URL,
        forScript script: URL,
        timestamp: Date
    ) -> Result<URL, ICloudCopyError> {

        // Build destination URL. The script's parent dir is the user-picked
        // folder (likely an iCloud-Drive path) and we sit a sibling .mov
        // next to the .md.
        let scriptStem = script.deletingPathExtension().lastPathComponent
        // Strip the colons APFS allows but sync layers dislike. The
        // resulting stamp is `2026-04-25T191455Z`-shaped — sortable but
        // safe across iCloud Drive / Files paths.
        let isoStamp = ISO8601DateFormatter.fileSafe
            .string(from: timestamp)
            .replacingOccurrences(of: ":", with: "")
        let parent = script.deletingLastPathComponent()
        let destination = parent.appendingPathComponent("\(scriptStem)__\(isoStamp).mov")

        // Check the source still exists — recovery scenarios sometimes call
        // this with a stale URL.
        guard FileManager.default.fileExists(atPath: recording.path) else {
            return .failure(.sourceMissing)
        }

        // The script's parent folder is security-scoped (the user picked it
        // via the folder picker and we hold a bookmark). The caller must
        // have already started access via `BookmarkStore`-managed lifecycle;
        // if we can't reach the parent, surface that as a permission failure.
        var coordinatorError: NSError?
        var copyError: ICloudCopyError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: destination,
            options: [.forReplacing],
            error: &coordinatorError
        ) { coordinatedDestination in
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: coordinatedDestination.path) {
                    try fm.removeItem(at: coordinatedDestination)
                }
                try fm.copyItem(at: recording, to: coordinatedDestination)
            } catch {
                copyError = .systemError(error.localizedDescription)
            }
        }
        if let coordinatorError {
            return .failure(.coordinatorError(coordinatorError.localizedDescription))
        }
        if let copyError {
            return .failure(copyError)
        }
        return .success(destination)
    }
}

/// Failure cases. `ICloudCopyError` is intentionally narrow — the caller
/// surfaces a single banner regardless of which case fires; we just keep
/// the message specific so the user knows what to do.
enum ICloudCopyError: Error, Equatable, Sendable {
    case sourceMissing
    case coordinatorError(String)
    case systemError(String)

    /// Banner copy. V2 Design 02 review note 4: "Saved to Photos. Couldn't
    /// save next to script — <reason>."
    var userMessage: String {
        switch self {
        case .sourceMissing:
            return "Recording file is gone — couldn't copy to script folder."
        case .coordinatorError(let msg):
            return "Couldn't reach script folder: \(msg)"
        case .systemError(let msg):
            return msg
        }
    }
}

extension ISO8601DateFormatter {
    /// Filesystem-safe timestamp formatter — colons are stripped because
    /// some sync layers (iCloud Drive in particular) get unhappy about
    /// colons in filenames despite APFS allowing them.
    static let fileSafe: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withTimeZone]
        return f
    }()
}

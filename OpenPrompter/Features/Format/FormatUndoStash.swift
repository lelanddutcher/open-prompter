//
//  FormatUndoStash.swift
//  OpenPrompter
//
//  Belt-and-suspenders crash stash for the Format action. On Apply we write
//  the PRE-format text to `Documents/FormatUndo/<hash>.md` so that if the app
//  is killed between Apply and Save, the next open of that script can offer a
//  one-time "Restore pre-Format version?" banner (mirrors the recording
//  RecoveryBanner pattern). The stash is deleted after a successful
//  Save-of-formatted or an explicit Undo — the design's guarantee that we are
//  NEVER in a state where the pre-format source is unrecoverable.
//
//  The filename is a DETERMINISTIC hash of the script's file URL so the same
//  script always maps to the same stash slot across launches. We can't use
//  Swift's `Hasher` (per-process randomized) — an FNV-1a over the URL string
//  is stable and collision-safe enough for a per-file scratch slot.
//
//  The base directory is injectable so tests use a temp directory, not the
//  real container.
//

import Foundation

/// Reads / writes the pre-format scratch copy for one script.
struct FormatUndoStash: Sendable {
    /// Directory holding the scratch `.md` files. Injected in tests.
    let directory: URL

    /// Default stash location: `Documents/FormatUndo/`.
    static var defaultDirectory: URL {
        let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("FormatUndo", isDirectory: true)
    }

    init(directory: URL = FormatUndoStash.defaultDirectory) {
        self.directory = directory
    }

    /// Stable filename for a script URL — a 16-hex-digit FNV-1a of the URL
    /// string, with `.md` extension. Deterministic across launches.
    static func fileName(for scriptURL: URL) -> String {
        "\(fnv1aHex(scriptURL.absoluteString)).md"
    }

    /// The stash file URL for a given script.
    func stashURL(for scriptURL: URL) -> URL {
        directory.appendingPathComponent(Self.fileName(for: scriptURL), isDirectory: false)
    }

    /// Write the pre-format text for a script. Coordinated via
    /// `FileCoordinatorReader` (per the design) so a concurrent iCloud sync
    /// on the container doesn't race the write.
    func write(preFormatText: String, for scriptURL: URL) async throws {
        try ensureDirectory()
        try await FileCoordinatorReader.writeAsync(preFormatText, to: stashURL(for: scriptURL))
    }

    /// Read a stashed pre-format copy if one exists for the script, else nil.
    func read(for scriptURL: URL) -> String? {
        let url = stashURL(for: scriptURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? FileCoordinatorReader.read(url)
    }

    /// True when a stash exists for the script (drives the restore banner).
    func hasStash(for scriptURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: stashURL(for: scriptURL).path)
    }

    /// Delete the stash for a script (after a clean Save-of-formatted or an
    /// explicit Undo). Silent if already gone.
    func clear(for scriptURL: URL) {
        try? FileManager.default.removeItem(at: stashURL(for: scriptURL))
    }

    // MARK: - Internals

    @discardableResult
    func ensureDirectory() throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// FNV-1a 64-bit over UTF-8 bytes, rendered as 16 lowercase hex digits.
    /// Deterministic and process-independent (unlike `Hasher`).
    static func fnv1aHex(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(hash, radix: 16)
    }
}

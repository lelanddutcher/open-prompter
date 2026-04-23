//
//  FileCoordinatorReader.swift
//  OpenPrompter
//
//  Thin wrapper around NSFileCoordinator for coordinated reads and writes
//  of iCloud-ubiquitous documents. Callers are expected to have already
//  called startAccessingSecurityScopedResource on the file's parent folder.
//

import Foundation

enum FileCoordinatorReader {
    enum Error: Swift.Error, LocalizedError {
        case readFailed(Swift.Error)
        case writeFailed(Swift.Error)
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .readFailed(let e): return "Could not read file: \(e.localizedDescription)"
            case .writeFailed(let e): return "Could not write file: \(e.localizedDescription)"
            case .decodeFailed: return "Could not decode file as UTF-8 text."
            }
        }
    }

    /// Coordinated read of a file as UTF-8 text.
    /// Throws `Error.readFailed` on NSFileCoordinator errors.
    /// Throws `Error.decodeFailed` if the bytes don't round-trip through UTF-8.
    static func read(_ url: URL) throws -> String {
        var readError: NSError?
        var text: String?
        var innerError: Swift.Error?

        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            readingItemAt: url,
            options: [.withoutChanges],
            error: &readError
        ) { coordinatedURL in
            do {
                let data = try Data(contentsOf: coordinatedURL)
                guard let decoded = String(data: data, encoding: .utf8) else {
                    innerError = Error.decodeFailed
                    return
                }
                text = decoded
            } catch {
                innerError = error
            }
        }

        if let err = readError { throw Error.readFailed(err) }
        if let err = innerError { throw err }
        guard let text else { throw Error.decodeFailed }
        return text
    }

    /// Coordinated write of UTF-8 text to a file.
    static func write(_ text: String, to url: URL) throws {
        var writeError: NSError?
        var innerError: Swift.Error?

        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: url,
            options: [.forReplacing],
            error: &writeError
        ) { coordinatedURL in
            do {
                // Data(text.utf8) is non-failable and preserves control
                // characters that `data(using: .utf8)` sometimes rejects.
                try Data(text.utf8).write(to: coordinatedURL, options: .atomic)
            } catch {
                innerError = error
            }
        }

        if let err = writeError { throw Error.writeFailed(err) }
        if let err = innerError { throw Error.writeFailed(err) }
    }

    /// Asynchronously read. Hops off the main actor via Task.detached so the
    /// coordinator callback (which can block) doesn't tie up the UI.
    static func readAsync(_ url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try read(url)
        }.value
    }

    static func writeAsync(_ text: String, to url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try write(text, to: url)
        }.value
    }
}

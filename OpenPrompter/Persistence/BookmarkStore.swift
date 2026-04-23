//
//  BookmarkStore.swift
//  OpenPrompter
//
//  Security-scoped bookmark I/O. "Pick once, remember forever" — the user
//  selects their iCloud Drive / Obsidian vault folder once via
//  UIDocumentPickerViewController, and we persist a bookmark that survives
//  relaunches and iOS restarts.
//
//  Bookmarks can go stale after iOS updates or if the user moves the folder.
//  Callers MUST handle `resolve()` returning nil or throwing and re-prompt
//  for folder selection gracefully.
//

import Foundation

enum BookmarkStore {
    enum Error: Swift.Error, LocalizedError {
        case saveFailed(Swift.Error)
        case resolveFailed(Swift.Error)
        case bookmarkStale

        var errorDescription: String? {
            switch self {
            case .saveFailed(let e): return "Could not save folder bookmark: \(e.localizedDescription)"
            case .resolveFailed(let e): return "Could not resolve folder bookmark: \(e.localizedDescription)"
            case .bookmarkStale: return "The saved folder is no longer accessible. Please pick it again."
            }
        }
    }

    private static let defaultsKey = "pref.folderBookmark"

    /// Persist a security-scoped bookmark for `url` to UserDefaults.
    /// Caller should have already called `startAccessingSecurityScopedResource()`
    /// on the URL returned by UIDocumentPickerViewController before calling this.
    static func save(_ url: URL) throws {
        do {
            #if os(iOS)
            let data = try url.bookmarkData(
                options: [.minimalBookmark],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            #else
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            #endif
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } catch {
            throw Error.saveFailed(error)
        }
    }

    /// Resolve the persisted bookmark back to a URL. Returns nil if no
    /// bookmark has been saved. Throws if the bookmark exists but cannot
    /// be resolved (bookmark data corrupted, folder deleted, etc.).
    static func resolve() throws -> URL? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            return nil
        }

        do {
            var isStale = false
            #if os(iOS)
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            #else
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            #endif

            if isStale {
                // Try to refresh the bookmark in place. If the folder still
                // exists at the same URL, we can re-bookmark it. If not,
                // surface bookmarkStale and let the caller re-prompt.
                do {
                    try save(url)
                } catch {
                    throw Error.bookmarkStale
                }
            }

            return url
        } catch let openError as Error {
            throw openError
        } catch {
            throw Error.resolveFailed(error)
        }
    }

    /// Remove the persisted bookmark. Used for "Change folder" and sign-out cases.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// True if a bookmark is currently persisted. Does NOT verify resolvability.
    static var hasBookmark: Bool {
        UserDefaults.standard.data(forKey: defaultsKey) != nil
    }
}

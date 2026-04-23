//
//  RecentsStore.swift
//  OpenPrompter
//
//  Thin API around the SwiftData ModelContainer for RecentScript. Encapsulates
//  insert/update/fetch logic so views and view models don't need to know
//  about ModelContext plumbing.
//

import Foundation
import SwiftData

@MainActor
final class RecentsStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Insert-or-update a recent entry for this URL.
    func record(
        file: ScriptFile,
        parsedBody: String
    ) {
        let urlString = file.url.absoluteString
        let predicate = #Predicate<RecentScript> { $0.urlString == urlString }
        let descriptor = FetchDescriptor<RecentScript>(predicate: predicate)

        do {
            if let existing = try context.fetch(descriptor).first {
                existing.lastOpenedAt = .now
                existing.cachedBody = parsedBody
                existing.mtime = file.mtime
            } else {
                let entry = RecentScript(
                    url: file.url,
                    cachedBody: parsedBody,
                    mtime: file.mtime
                )
                context.insert(entry)
            }
            try context.save()
        } catch {
            // Non-fatal — a failed recent write shouldn't interrupt the session.
            #if DEBUG
            print("[RecentsStore] record failed: \(error)")
            #endif
        }
    }

    func recents(limit: Int = 10) -> [RecentScript] {
        var descriptor = FetchDescriptor<RecentScript>(
            sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        do {
            return try context.fetch(descriptor)
        } catch {
            return []
        }
    }

    func last() -> RecentScript? {
        recents(limit: 1).first
    }

    func delete(_ script: RecentScript) {
        context.delete(script)
        try? context.save()
    }

    func clearAll() {
        let all = (try? context.fetch(FetchDescriptor<RecentScript>())) ?? []
        for entry in all { context.delete(entry) }
        try? context.save()
    }
}

//
//  RecentScript.swift
//  OpenPrompter
//
//  SwiftData @Model for tracking recently opened scripts. Stores a stale-safe
//  cached copy of the last-parsed body so the app can render instantly on
//  cold launch while iCloud syncs in the background.
//

import Foundation
import SwiftData

@Model
final class RecentScript {
    @Attribute(.unique) var id: UUID
    var urlString: String
    var lastOpenedAt: Date
    var cachedBody: String
    var mtime: Date
    var favorite: Bool

    init(
        id: UUID = UUID(),
        url: URL,
        cachedBody: String,
        mtime: Date,
        favorite: Bool = false
    ) {
        self.id = id
        self.urlString = url.absoluteString
        self.lastOpenedAt = .now
        self.cachedBody = cachedBody
        self.mtime = mtime
        self.favorite = favorite
    }

    var url: URL? { URL(string: urlString) }
}

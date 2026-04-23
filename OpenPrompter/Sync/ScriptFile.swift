//
//  ScriptFile.swift
//  OpenPrompter
//
//  Identified file descriptor used throughout the app to refer to a markdown
//  script on disk. Value type, Sendable, Hashable by URL.
//

import Foundation

struct ScriptFile: Identifiable, Hashable, Sendable {
    /// Mirrors the three Apple-defined ubiquitous download states.
    /// See: NSMetadataUbiquitousItemDownloadingStatusKey values.
    enum DownloadState: String, Sendable {
        /// File is downloaded AND the local copy is the most recent version.
        case current = "NSMetadataUbiquitousItemDownloadingStatusCurrent"
        /// File is downloaded locally but may be out of date vs. the cloud.
        case downloaded = "NSMetadataUbiquitousItemDownloadingStatusDownloaded"
        /// File has not been downloaded to this device yet.
        case notDownloaded = "NSMetadataUbiquitousItemDownloadingStatusNotDownloaded"

        /// Convenience: is the file readable locally right now?
        var isLocal: Bool {
            switch self {
            case .current, .downloaded: return true
            case .notDownloaded: return false
            }
        }
    }

    let id: URL
    let name: String
    let mtime: Date
    let downloadState: DownloadState

    var url: URL { id }
    var displayName: String {
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }
}

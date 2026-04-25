//
//  UbiquitousPrefsMirror.swift
//  OpenPrompter
//
//  Mirrors selected preferences between UserDefaults and
//  NSUbiquitousKeyValueStore so that user-facing settings follow the user
//  across devices signed into the same iCloud account.
//
//  Only the default scalar prefs are mirrored — NOT the folder bookmark
//  (bookmarks are device-local per Apple guidance) and NOT the last-file URL
//  (only meaningful on the device that opened it).
//

import Foundation

enum UbiquitousPrefsMirror {
    private static let mirroredKeys: [PrefKey] = [
        .defaultSpeed,
        .defaultFont,
        .prompterFont,
        // The legacy single-axis mirror key is still mirrored so an older
        // build on a sibling device sees the user's most recent choice.
        // The new per-axis keys travel alongside it.
        .mirrorDefault,
        .hMirrorDefault,
        .vMirrorDefault,
        .focusDefault,
        .aggressiveStripping,
        .appearance,
        // Camera Style + PiP (V2 Feature 1). The labs flag and the coach
        // mark stay device-local: a flag that's on for one device shouldn't
        // light up an unprepared sibling, and "I've seen this banner once"
        // is per-device per existing pattern (see coachMarkPlayShown etc.).
        .cameraStyle,
        .cameraFacingFront,
        .cameraPipSize,
        .cameraPipCornerLast
    ]

    private static var observerToken: NSObjectProtocol?

    /// Start mirroring. Safe to call once at app launch.
    /// Pulls any remote changes immediately, then listens for future pushes.
    static func start() {
        if observerToken == nil {
            observerToken = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: NSUbiquitousKeyValueStore.default,
                queue: .main
            ) { _ in
                pullFromCloud()
            }
        }
        NSUbiquitousKeyValueStore.default.synchronize()
        pullFromCloud()
    }

    /// Push current local preferences to iCloud.
    static func pushToCloud() {
        let kv = NSUbiquitousKeyValueStore.default
        let defaults = UserDefaults.standard
        for key in mirroredKeys {
            if let value = defaults.object(forKey: key.rawValue) {
                kv.set(value, forKey: key.rawValue)
            }
        }
        kv.synchronize()
    }

    /// Pull iCloud values into UserDefaults, overwriting local.
    /// Only called on external change notifications, not blindly.
    static func pullFromCloud() {
        let kv = NSUbiquitousKeyValueStore.default
        let defaults = UserDefaults.standard
        for key in mirroredKeys {
            if let value = kv.object(forKey: key.rawValue) {
                defaults.set(value, forKey: key.rawValue)
            }
        }
    }
}

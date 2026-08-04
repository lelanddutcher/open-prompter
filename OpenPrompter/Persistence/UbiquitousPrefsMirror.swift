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

/// Minimal key-value-store abstraction so the mirror can be exercised without
/// touching the real iCloud store. `NSUbiquitousKeyValueStore` satisfies it
/// as-is (the signatures match); tests inject an in-memory fake.
///
/// WHY THIS EXISTS: `NSUbiquitousKeyValueStore` silently no-ops when no iCloud
/// account is signed in, so a test asserting against the real store fails on
/// any clean machine — reported by an outside contributor who cloned the repo
/// (2026-08-04). It passed here only because a long-lived simulator masked it.
/// This seam keeps mirror tests hermetic. The APP path is unchanged: every
/// parameter below defaults to the real store.
protocol KeyValueStoring: AnyObject {
    func object(forKey aKey: String) -> Any?
    func set(_ anObject: Any?, forKey aKey: String)
    @discardableResult
    func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KeyValueStoring {}

enum UbiquitousPrefsMirror {
    /// Keys mirrored between `UserDefaults` and iCloud KVS. Deliberately
    /// `internal` rather than `private` so tests can assert the list DIRECTLY
    /// instead of inferring its contents from a live cloud round-trip.
    static let mirroredKeys: [PrefKey] = [
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
        // Stage-direction / camera-cue display stripping (V3 item 4). A
        // display-formatting preference the user expects to follow them across
        // devices, so it mirrors alongside `aggressiveStripping`.
        .stripStageDirections,
        .appearance,
        // Camera Style + PiP (V2 Feature 1). The labs flag and the coach
        // mark stay device-local: a flag that's on for one device shouldn't
        // light up an unprepared sibling, and "I've seen this banner once"
        // is per-device per existing pattern (see coachMarkPlayShown etc.).
        // PiP tile position mirrors so the user's preferred eye-line spot
        // travels with them across paired devices.
        .cameraStyle,
        .cameraPipSize,
        .cameraPipPositionX,
        .cameraPipPositionY,
        // Recording (Feature 2 + 4) mirrors the cross-device preferences.
        // `recordingMicSource` is intentionally excluded — paths to specific
        // accessories don't survive across devices and pinning AirPods on
        // an iPhone shouldn't pin them on an iPad that doesn't see them.
        // The aspect-ratio coach mark stays device-local (per the existing
        // coach-mark pattern); only the user's chosen aspect mirrors.
        .recordingQuality,
        .recordingFramerate,
        .recordingStabilization,
        .recordingCountdown,
        .recordingIndicator,
        .recordingSaveToScriptFolder,
        .recordingAspect,
        // 3.1: both are cross-device preferences, not per-device capability
        // flags — a creator who wants selfie-mirrored takes, or who hides the
        // progress bar, expects that to follow them.
        .recordingMirrorVideo,
        .showReadingProgressBar,
        // Video markers (V3 headline). Both marker-output toggles travel with
        // the user — a creator's "write markers" preference is not per-device.
        .recordingMarkerMetadataTrack,
        .recordingMarkerChapterTrack,
        // On-device Format (V3 item C). Only the three prompt strings
        // mirror — they're small text and the user expects an edited prompt
        // to follow them across devices. The `labsFormat` flag and
        // `coachMarkFormatShown` stay device-local (capability + "seen once"
        // are per-device, matching the labs / coach-mark pattern). The custom
        // preset NAME travels alongside its prompt.
        .formatPromptFormatOverride,
        .formatPromptCleanupOverride,
        .formatPromptCustom,
        .formatCustomName
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

    /// Push current local preferences to iCloud. Both stores are injectable
    /// (defaulting to the real ones) purely so tests can run hermetically —
    /// the app calls this with no arguments and behaves exactly as before.
    static func pushToCloud(
        to kv: any KeyValueStoring = NSUbiquitousKeyValueStore.default,
        from defaults: UserDefaults = .standard
    ) {
        for key in mirroredKeys {
            if let value = defaults.object(forKey: key.rawValue) {
                kv.set(value, forKey: key.rawValue)
            }
        }
        kv.synchronize()
    }

    /// Pull iCloud values into UserDefaults, overwriting local.
    /// Only called on external change notifications, not blindly.
    /// Injectable for the same test-hermeticity reason as `pushToCloud`.
    static func pullFromCloud(
        from kv: any KeyValueStoring = NSUbiquitousKeyValueStore.default,
        into defaults: UserDefaults = .standard
    ) {
        for key in mirroredKeys {
            if let value = kv.object(forKey: key.rawValue) {
                defaults.set(value, forKey: key.rawValue)
            }
        }
    }
}

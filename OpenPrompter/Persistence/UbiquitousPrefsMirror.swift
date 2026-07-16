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

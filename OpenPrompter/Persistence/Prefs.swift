//
//  Prefs.swift
//  OpenPrompter
//
//  UserDefaults-backed preference storage. Scalar values that the user tunes
//  (default speed, default font, mirror default, focus default, stripping mode).
//  Mirrored to NSUbiquitousKeyValueStore so preferences follow the user across
//  their iPhone + future iPad.
//

import Foundation
import SwiftUI

enum PrefKey: String, CaseIterable {
    case defaultSpeed = "pref.defaultSpeed"
    case defaultFont = "pref.defaultFont"
    case prompterFont = "pref.prompterFont"
    /// Legacy single-axis mirror default. Superseded by `hMirrorDefault`
    /// (and the new `vMirrorDefault`) in the v2 second-axis work. Kept in
    /// the enum so a one-shot migration can read it; left written in
    /// UserDefaults rather than removed so a downgrade or older build
    /// doesn't lose the user's choice.
    case mirrorDefault = "pref.mirrorDefault"
    case hMirrorDefault = "pref.hMirrorDefault"
    case vMirrorDefault = "pref.vMirrorDefault"
    case focusDefault = "pref.focusDefault"
    case aggressiveStripping = "pref.aggressiveStripping"
    case lastFileURL = "pref.lastFileURL"
    case onboardingCompleted = "pref.onboardingCompleted"
    case coachMarkPlayShown = "pref.coachMarkPlayShown"
    case coachMarkMirrorShown = "pref.coachMarkMirrorShown"
    case appearance = "pref.appearance"
    /// Master toggle for the Bluetooth remote feature (Feature 7).
    /// Default true so once Labs exposes Remote Control, the user gets
    /// keyboard/media-key control immediately without an extra step.
    case remoteEnabled = "pref.remote.enabled"
    /// Opt-in for the volume-button event source. OFF by default — the
    /// inverse capture pattern protects against App Store guideline 2.5.9.
    /// Settings copy explains the trade-off when the user enables it.
    case useVolumeButtons = "pref.remote.useVolumeButtons"
    /// Labs feature flag for Bluetooth remote. Defaults to ON in DEBUG, OFF
    /// in Release until the feature is shipped — see `OpenPrompterApp.swift`
    /// where `Prefs.register()` reads `#if DEBUG` to set the right default.
    case labsBluetoothRemote = "labs.bluetoothRemote"
    // MARK: - Camera Style + PiP (V2 Feature 1)
    /// User's chosen camera composition mode. Stored as a string so the
    /// JSON shape stays stable if we add a new mode (e.g. floating preview)
    /// without invalidating sibling devices' iCloud KVS payloads.
    /// First-run default: `"off"` — privacy-respecting, no surprise camera
    /// permission prompt on first prompter open after the v2 update.
    case cameraStyle = "pref.camera.style"
    /// Last-used PiP tile size. Persisted between launches.
    case cameraPipSize = "pref.camera.pipSize"
    /// Last absolute X position of the PiP tile, normalized 0..1 across the
    /// viewport's width. The tile is placed wherever the user dropped it —
    /// no corner snapping. Default `0.5` (horizontally centered) — pairs
    /// with `cameraPipPositionY` `~0.22` to put the tile under the front
    /// camera lens for natural eye-line.
    case cameraPipPositionX = "pref.camera.pipPositionX"
    /// Last absolute Y position of the PiP tile, normalized 0..1 across the
    /// viewport's height. Default `0.22` — roughly under the dynamic
    /// island / lens. Clamped to safe areas at runtime.
    case cameraPipPositionY = "pref.camera.pipPositionY"
    /// Labs feature flag for Camera Style. Defaults ON in DEBUG, OFF in
    /// Release until the feature graduates from Labs.
    case labsCameraStyle = "labs.cameraStyle"
    /// One-shot "Try the new camera modes" banner on first prompter open
    /// after the v2 update. Coach marks stay device-local — not mirrored
    /// to iCloud KVS.
    case coachMarkCameraStyleShown = "pref.coachMarkCameraStyleShown"

    // MARK: - Recording (V2 Feature 2 + 4)

    /// Recording quality tier — `"standard"` or `"high"`. Default `"high"`
    /// (V2 Design 02 review note 8 collapsed the picker to two tiers).
    /// Mirrored to iCloud KVS so the user's preference travels.
    case recordingQuality = "pref.recording.quality"
    /// Recording framerate — `"fps24"`, `"fps30"`, or `"fps60"`. Default
    /// `"fps30"` (social-platform standard). Mirrored.
    case recordingFramerate = "pref.recording.framerate"
    /// Pinned microphone source. Stored as the AVAudioSession port UID so
    /// the pin persists across reconnects (the same accessory keeps the
    /// same UID even after a power-cycle). Two reserved values: `"auto"`
    /// (let iOS pick — explicit opt-in to fallback behavior) and
    /// `"builtin"` (default). Per-device — NOT mirrored to iCloud, since
    /// a paired iPad will see a different set of accessories.
    case recordingMicSource = "pref.recording.micSource"
    /// Stabilization mode — `"off"` / `"standard"` / `"cinematic"`. Default
    /// `"off"` (mounted-rig assumption per V2 Design 02 §"Stabilization").
    /// Mirrored.
    case recordingStabilization = "pref.recording.stabilization"
    /// Pre-roll countdown — `"off"` / `"three"` / `"five"`. Default `"three"`
    /// per review note 2. Mirrored.
    case recordingCountdown = "pref.recording.countdown"
    /// Recording indicator preference — `"islandOnly"` / `"both"` /
    /// `"tallyOnly"`. Default is `"both"` on Dynamic Island devices,
    /// `"tallyOnly"` on non-island devices (review note 6). The default is
    /// computed at first read in `Prefs.recordingIndicator`. Mirrored.
    case recordingIndicator = "pref.recording.indicator"
    /// "Also save next to script" toggle. Default `false`. Mirrored.
    case recordingSaveToScriptFolder = "pref.recording.saveToScriptFolder"
    /// Labs feature flag for the recording feature. Defaults ON in DEBUG,
    /// OFF in Release until the feature graduates from Labs.
    case labsRecording = "labs.recording"
    /// One-shot acknowledgment of the Photos write-only permission prompt.
    /// We use this to tell whether we've already prompted on this device,
    /// so the chip doesn't fire the system prompt twice in a single take.
    case recordingPhotosPermissionAsked = "pref.recording.photosPermissionAsked"

    // MARK: - App Store review prompt (Feature 8)
    //
    // Counters + bookkeeping for `SKStoreReviewController.requestReview(in:)`.
    // We only ask once per CFBundleShortVersionString and only after the
    // user has demonstrated meaningful engagement (recorded a take OR
    // played multiple prompter sessions) AND ≥ 24 hours have elapsed
    // since first launch. Apple's StoreKit additionally rate-limits to
    // 3 prompts per 365 days per Apple ID; this layer keeps us from
    // burning that budget on a freshly-installed user.

    /// Number of recordings the user has completed AND saved successfully.
    /// Increments only after the Photos write resolves (success path).
    case reviewRecordingsCompleted = "pref.review.recordingsCompleted"
    /// Number of prompter playback sessions the user has finished. A
    /// "session" is play → pause / end-of-script with at least 30 s of
    /// elapsed playback time, so a tap-then-pause doesn't count.
    case reviewPlaySessionsCompleted = "pref.review.playSessionsCompleted"
    /// Cumulative playback seconds across the lifetime of the app on
    /// this device. Stored alongside session count so we can layer on
    /// a duration threshold later if needed.
    case reviewTotalPlaybackSeconds = "pref.review.totalPlaybackSeconds"
    /// ISO-8601 timestamp of the user's first launch on this device.
    /// Used for the 24-hour "don't ask freshly-installed users" gate.
    /// Stored as ISO string (not TimeInterval) so a Files inspection
    /// shows a readable value.
    case reviewFirstLaunchAt = "pref.review.firstLaunchAt"
    /// CFBundleShortVersionString we last prompted under. Empty string
    /// means we've never prompted. Comparing against the current bundle
    /// version is what enforces "once per app version."
    case reviewLastPromptedAppVersion = "pref.review.lastPromptedAppVersion"

    var defaultValue: Any {
        switch self {
        case .defaultSpeed: return 48.0        // pixels per second
        case .defaultFont: return 64.0         // points
        case .prompterFont: return PrompterFont.default.rawValue
        case .mirrorDefault: return false
        case .hMirrorDefault: return false
        case .vMirrorDefault: return false
        case .focusDefault: return false
        case .aggressiveStripping: return true
        case .lastFileURL: return ""
        case .onboardingCompleted: return false
        case .coachMarkPlayShown: return false
        case .coachMarkMirrorShown: return false
        case .appearance: return Prefs.Appearance.dark.rawValue
        case .remoteEnabled: return true
        case .useVolumeButtons: return false
        case .labsBluetoothRemote:
            // In DEBUG builds we default Labs flags to ON so internal builds
            // exercise the in-progress feature. Release builds default OFF
            // so end users only see Labs entries they've explicitly enabled.
            #if DEBUG
            return true
            #else
            return false
            #endif
        case .cameraStyle:           return "off"
        case .cameraPipSize:         return "medium"
        case .cameraPipPositionX:    return 0.5
        case .cameraPipPositionY:    return 0.22
        case .labsCameraStyle:
            #if DEBUG
            return true
            #else
            return false
            #endif
        case .coachMarkCameraStyleShown: return false
        case .recordingQuality:        return "high"
        case .recordingFramerate:      return "fps30"
        case .recordingMicSource:      return "builtin"
        case .recordingStabilization:  return "off"
        case .recordingCountdown:      return "three"
        // The default is filled in lazily by `Prefs.recordingIndicator`
        // because it depends on whether the running device supports Live
        // Activities. Storing a stable string here means a non-island
        // device upgrading later still sees a sane value if the runtime
        // check ever fails.
        case .recordingIndicator:      return "both"
        case .recordingSaveToScriptFolder: return false
        case .labsRecording:
            #if DEBUG
            return true
            #else
            return false
            #endif
        case .recordingPhotosPermissionAsked: return false
        case .reviewRecordingsCompleted: return 0
        case .reviewPlaySessionsCompleted: return 0
        case .reviewTotalPlaybackSeconds: return 0.0
        case .reviewFirstLaunchAt: return ""
        case .reviewLastPromptedAppVersion: return ""
        }
    }
}

enum Prefs {
    private static let defaults: UserDefaults = .standard

    /// User-facing appearance preference for the library/settings/picker UI.
    /// The teleprompter reading view itself is pinned to dark regardless of
    /// this choice — a bright screen behind teleprompter glass creates glare.
    enum Appearance: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }
    }

    static func register() {
        // Migration must consult only the persistent (on-disk) domain so
        // it can tell "user wrote this" from "framework registered a
        // fallback". Pass the main bundle identifier so we read the app's
        // own .plist and not anything in the global registration domain.
        let domain = Bundle.main.bundleIdentifier ?? ""
        migrateLegacyMirrorKey(in: defaults, domain: domain)

        var initial: [String: Any] = [:]
        for key in PrefKey.allCases {
            initial[key.rawValue] = key.defaultValue
        }
        defaults.register(defaults: initial)
    }

    /// One-shot migration from the legacy single-axis mirror key
    /// (`pref.mirrorDefault`) to the new horizontal-axis key
    /// (`pref.hMirrorDefault`). Idempotent: only copies when the user has
    /// explicitly written the legacy key AND has not yet written to the new
    /// key. The legacy key is left in place so a downgrade still finds the
    /// user's preference.
    ///
    /// `domain` is the persistent domain to inspect (typically the app's
    /// bundle identifier). Reading via `persistentDomain(forName:)` skips
    /// the process-wide registration domain so framework-default fallbacks
    /// don't masquerade as user writes.
    static func migrateLegacyMirrorKey(in store: UserDefaults, domain: String) {
        let legacyKey = PrefKey.mirrorDefault.rawValue
        let newKey = PrefKey.hMirrorDefault.rawValue
        let persistent = store.persistentDomain(forName: domain) ?? [:]
        guard persistent[legacyKey] != nil,
              persistent[newKey] == nil else { return }
        let legacyValue = (persistent[legacyKey] as? Bool) ?? false
        store.set(legacyValue, forKey: newKey)
    }

    // MARK: - Scalar accessors

    static var defaultSpeed: Double {
        get { defaults.double(forKey: PrefKey.defaultSpeed.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.defaultSpeed.rawValue) }
    }

    static var defaultFont: Double {
        get { defaults.double(forKey: PrefKey.defaultFont.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.defaultFont.rawValue) }
    }

    /// Raw value of the selected `PrompterFont`. Stored as `String` so we
    /// can extend the enum without a migration. Reads always fall back to
    /// `PrompterFont.default` if the stored value is missing or unknown.
    static var prompterFont: PrompterFont {
        get {
            let raw = defaults.string(forKey: PrefKey.prompterFont.rawValue)
                ?? PrompterFont.default.rawValue
            return PrompterFont(rawValue: raw) ?? .default
        }
        set { defaults.set(newValue.rawValue, forKey: PrefKey.prompterFont.rawValue) }
    }

    /// Legacy single-axis mirror default. Reads pass through to the new
    /// horizontal pref so any code path still on this name keeps working.
    /// Writes update both the legacy key and the new horizontal key so a
    /// downgrade still sees the user's latest choice.
    @available(*, deprecated, message: "Use hMirrorDefault / vMirrorDefault.")
    static var mirrorDefault: Bool {
        get { defaults.bool(forKey: PrefKey.hMirrorDefault.rawValue) }
        set {
            defaults.set(newValue, forKey: PrefKey.hMirrorDefault.rawValue)
            defaults.set(newValue, forKey: PrefKey.mirrorDefault.rawValue)
        }
    }

    /// Horizontal mirror (left ↔ right). The standard transform for
    /// beam-splitter teleprompter rigs. Default off.
    static var hMirrorDefault: Bool {
        get { defaults.bool(forKey: PrefKey.hMirrorDefault.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.hMirrorDefault.rawValue) }
    }

    /// Vertical mirror (top ↔ bottom). For periscope rigs and upside-down
    /// phone mounts. Combine with horizontal for a 180° rotation. Default off.
    static var vMirrorDefault: Bool {
        get { defaults.bool(forKey: PrefKey.vMirrorDefault.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.vMirrorDefault.rawValue) }
    }

    static var focusDefault: Bool {
        get { defaults.bool(forKey: PrefKey.focusDefault.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.focusDefault.rawValue) }
    }

    static var aggressiveStripping: Bool {
        get { defaults.bool(forKey: PrefKey.aggressiveStripping.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.aggressiveStripping.rawValue) }
    }

    static var lastFileURL: String {
        get { defaults.string(forKey: PrefKey.lastFileURL.rawValue) ?? "" }
        set { defaults.set(newValue, forKey: PrefKey.lastFileURL.rawValue) }
    }

    static var onboardingCompleted: Bool {
        get { defaults.bool(forKey: PrefKey.onboardingCompleted.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.onboardingCompleted.rawValue) }
    }

    static var coachMarkPlayShown: Bool {
        get { defaults.bool(forKey: PrefKey.coachMarkPlayShown.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.coachMarkPlayShown.rawValue) }
    }

    static var coachMarkMirrorShown: Bool {
        get { defaults.bool(forKey: PrefKey.coachMarkMirrorShown.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.coachMarkMirrorShown.rawValue) }
    }

    static var appearance: Appearance {
        get {
            let raw = defaults.string(forKey: PrefKey.appearance.rawValue)
                ?? Appearance.dark.rawValue
            return Appearance(rawValue: raw) ?? .dark
        }
        set { defaults.set(newValue.rawValue, forKey: PrefKey.appearance.rawValue) }
    }

    static var remoteEnabled: Bool {
        get { defaults.bool(forKey: PrefKey.remoteEnabled.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.remoteEnabled.rawValue) }
    }

    static var useVolumeButtons: Bool {
        get { defaults.bool(forKey: PrefKey.useVolumeButtons.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.useVolumeButtons.rawValue) }
    }

    static var labsBluetoothRemote: Bool {
        get { defaults.bool(forKey: PrefKey.labsBluetoothRemote.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.labsBluetoothRemote.rawValue) }
    }

    // MARK: - Camera Style + PiP (V2 Feature 1)

    /// Raw string of `CameraStyle`. Stored as a string so we can extend the
    /// enum without a migration (a downgrade reading an unknown value falls
    /// back to `.off`). Default is `"off"` — we never auto-prompt for
    /// camera permission on first run.
    static var cameraStyle: String {
        get { defaults.string(forKey: PrefKey.cameraStyle.rawValue) ?? "off" }
        set { defaults.set(newValue, forKey: PrefKey.cameraStyle.rawValue) }
    }

    /// Raw string of `PipSize`. Default `"medium"`.
    static var cameraPipSize: String {
        get { defaults.string(forKey: PrefKey.cameraPipSize.rawValue) ?? "medium" }
        set { defaults.set(newValue, forKey: PrefKey.cameraPipSize.rawValue) }
    }

    /// Normalized 0..1 X coordinate of the last drop point. The PiP tile is
    /// placed wherever the user released it; the runtime clamps to keep the
    /// tile within safe areas (top inset, bottom chrome strip).
    static var cameraPipPositionX: Double {
        get { defaults.double(forKey: PrefKey.cameraPipPositionX.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.cameraPipPositionX.rawValue) }
    }

    /// Normalized 0..1 Y coordinate of the last drop point. Default 0.22 —
    /// just under the front-camera lens / dynamic island so first launches
    /// put the eye-line where the user is already looking.
    static var cameraPipPositionY: Double {
        get { defaults.double(forKey: PrefKey.cameraPipPositionY.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.cameraPipPositionY.rawValue) }
    }

    static var labsCameraStyle: Bool {
        get { defaults.bool(forKey: PrefKey.labsCameraStyle.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.labsCameraStyle.rawValue) }
    }

    static var coachMarkCameraStyleShown: Bool {
        get { defaults.bool(forKey: PrefKey.coachMarkCameraStyleShown.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.coachMarkCameraStyleShown.rawValue) }
    }

    // MARK: - Recording (V2 Feature 2 + 4)

    /// Quality tier raw string. Reads always fall back to "high" if the
    /// stored value is missing or unknown (downgrade from a future tier
    /// shouldn't crash). Settings reads through this as a `RecordingQuality`
    /// enum.
    static var recordingQuality: String {
        get { defaults.string(forKey: PrefKey.recordingQuality.rawValue) ?? "high" }
        set { defaults.set(newValue, forKey: PrefKey.recordingQuality.rawValue) }
    }

    static var recordingFramerate: String {
        get { defaults.string(forKey: PrefKey.recordingFramerate.rawValue) ?? "fps30" }
        set { defaults.set(newValue, forKey: PrefKey.recordingFramerate.rawValue) }
    }

    /// Pinned mic source — port UID, "auto", or "builtin". See PrefKey
    /// docs above for why this is per-device.
    static var recordingMicSource: String? {
        get { defaults.string(forKey: PrefKey.recordingMicSource.rawValue) }
        set {
            if let v = newValue {
                defaults.set(v, forKey: PrefKey.recordingMicSource.rawValue)
            } else {
                defaults.removeObject(forKey: PrefKey.recordingMicSource.rawValue)
            }
        }
    }

    static var recordingStabilization: String {
        get { defaults.string(forKey: PrefKey.recordingStabilization.rawValue) ?? "off" }
        set { defaults.set(newValue, forKey: PrefKey.recordingStabilization.rawValue) }
    }

    static var recordingCountdown: String {
        get { defaults.string(forKey: PrefKey.recordingCountdown.rawValue) ?? "three" }
        set { defaults.set(newValue, forKey: PrefKey.recordingCountdown.rawValue) }
    }

    /// Recording indicator preference. Default depends on whether the
    /// running device supports Live Activities — a non-island device must
    /// land on `tallyOnly`, an island device on `both`. We resolve the
    /// default lazily on first read so a paired iPad / iPhone-without-
    /// island gets the right initial value without a manual migration.
    static var recordingIndicator: String {
        get {
            if let raw = defaults.string(forKey: PrefKey.recordingIndicator.rawValue),
               !raw.isEmpty {
                return raw
            }
            // No stored value yet — pick the device-appropriate default.
            #if canImport(ActivityKit)
            return RecordingIndicatorPref.default.rawValue
            #else
            return RecordingIndicatorPref.tallyOnly.rawValue
            #endif
        }
        set { defaults.set(newValue, forKey: PrefKey.recordingIndicator.rawValue) }
    }

    static var recordingSaveToScriptFolder: Bool {
        get { defaults.bool(forKey: PrefKey.recordingSaveToScriptFolder.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.recordingSaveToScriptFolder.rawValue) }
    }

    static var labsRecording: Bool {
        get { defaults.bool(forKey: PrefKey.labsRecording.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.labsRecording.rawValue) }
    }

    static var recordingPhotosPermissionAsked: Bool {
        get { defaults.bool(forKey: PrefKey.recordingPhotosPermissionAsked.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.recordingPhotosPermissionAsked.rawValue) }
    }

    // MARK: - App Store review prompt (Feature 8)

    static var reviewRecordingsCompleted: Int {
        get { defaults.integer(forKey: PrefKey.reviewRecordingsCompleted.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.reviewRecordingsCompleted.rawValue) }
    }

    static var reviewPlaySessionsCompleted: Int {
        get { defaults.integer(forKey: PrefKey.reviewPlaySessionsCompleted.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.reviewPlaySessionsCompleted.rawValue) }
    }

    static var reviewTotalPlaybackSeconds: Double {
        get { defaults.double(forKey: PrefKey.reviewTotalPlaybackSeconds.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.reviewTotalPlaybackSeconds.rawValue) }
    }

    /// First-launch timestamp. Lazily initialised on first read — if the
    /// stored value is empty (or unparseable) we stamp it with `Date.now`
    /// and write it back, so subsequent reads return a stable value.
    /// Decoded as an ISO-8601 string for human-readable Files inspection.
    static var reviewFirstLaunchAt: Date {
        get {
            let raw = defaults.string(forKey: PrefKey.reviewFirstLaunchAt.rawValue) ?? ""
            if !raw.isEmpty, let date = ISO8601DateFormatter().date(from: raw) {
                return date
            }
            let now = Date.now
            defaults.set(ISO8601DateFormatter().string(from: now),
                         forKey: PrefKey.reviewFirstLaunchAt.rawValue)
            return now
        }
        set {
            defaults.set(ISO8601DateFormatter().string(from: newValue),
                         forKey: PrefKey.reviewFirstLaunchAt.rawValue)
        }
    }

    static var reviewLastPromptedAppVersion: String {
        get { defaults.string(forKey: PrefKey.reviewLastPromptedAppVersion.rawValue) ?? "" }
        set { defaults.set(newValue, forKey: PrefKey.reviewLastPromptedAppVersion.rawValue) }
    }
}

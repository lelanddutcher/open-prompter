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
}

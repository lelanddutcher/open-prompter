//
//  CameraStyle.swift
//  OpenPrompter
//
//  Three-mode camera composition picker. See Roadmap V2 §1 and
//  V2 Design 01 for the rationale behind each mode.
//
//  - `pip`     small portrait tile + full-frame text. Marquee mode.
//  - `behind`  full-frame camera, prompter text scrolls over a scrim.
//  - `off`     no camera session at all. Privacy-respecting first-run default.
//
//  Stored as a string in `Prefs.cameraStyle` so the JSON shape stays stable
//  even if we add a fourth mode (e.g. picture-in-picture-out for floating
//  preview) — `Codable` round-trip is unit-tested.
//

import Foundation

/// User-facing camera composition mode in the prompter view.
///
/// The string raw values are serialized into UserDefaults / iCloud KVS via
/// `Prefs.cameraStyle`; do NOT rename them without a migration.
enum CameraStyle: String, CaseIterable, Codable, Hashable, Sendable {
    case pip
    case behind
    case off

    /// Lowercase mono label used by the bottom-bar chip and the Settings
    /// picker. Keep these in sync with V2 Design 01 §"The Camera Style
    /// picker chip" — the label below the icon on the chip.
    var displayName: String {
        switch self {
        case .pip:    return "pip"
        case .behind: return "behind"
        case .off:    return "no camera"
        }
    }

    /// Longer copy for the Settings picker so the user knows what each
    /// choice maps to. The chip itself uses `displayName`.
    var settingsDisplayName: String {
        switch self {
        case .pip:    return "picture-in-picture"
        case .behind: return "behind text"
        case .off:    return "off"
        }
    }

    /// SF Symbol name for the chip glyph. Picked to match the in-prompter
    /// chip language (filled rectangles for "tile in a frame", eye-slash for
    /// privacy-off). Update both the chip and the Settings row if these change.
    var symbolName: String {
        switch self {
        case .pip:    return "rectangle.inset.filled.and.person.filled"
        case .behind: return "person.and.background.dotted"
        case .off:    return "eye.slash"
        }
    }

    /// Cycle order for the chip tap gesture. `off → pip → behind → off`,
    /// per V2 Design 01 §"Gestures on the chip".
    var nextStyle: CameraStyle {
        switch self {
        case .off:    return .pip
        case .pip:    return .behind
        case .behind: return .off
        }
    }

    /// True when this mode requires the camera permission prompt. `off` is
    /// the privacy-safe fallback we land on if permission is denied.
    var requiresCameraPermission: Bool {
        self != .off
    }
}

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
    case mirrorDefault = "pref.mirrorDefault"
    case focusDefault = "pref.focusDefault"
    case aggressiveStripping = "pref.aggressiveStripping"
    case lastFileURL = "pref.lastFileURL"
    case onboardingCompleted = "pref.onboardingCompleted"
    case coachMarkPlayShown = "pref.coachMarkPlayShown"
    case coachMarkMirrorShown = "pref.coachMarkMirrorShown"
    case appearance = "pref.appearance"

    var defaultValue: Any {
        switch self {
        case .defaultSpeed: return 48.0        // pixels per second
        case .defaultFont: return 64.0         // points
        case .prompterFont: return PrompterFont.default.rawValue
        case .mirrorDefault: return false
        case .focusDefault: return false
        case .aggressiveStripping: return true
        case .lastFileURL: return ""
        case .onboardingCompleted: return false
        case .coachMarkPlayShown: return false
        case .coachMarkMirrorShown: return false
        case .appearance: return Prefs.Appearance.dark.rawValue
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
        var initial: [String: Any] = [:]
        for key in PrefKey.allCases {
            initial[key.rawValue] = key.defaultValue
        }
        defaults.register(defaults: initial)
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

    static var mirrorDefault: Bool {
        get { defaults.bool(forKey: PrefKey.mirrorDefault.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.mirrorDefault.rawValue) }
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
}

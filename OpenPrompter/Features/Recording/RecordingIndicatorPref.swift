//
//  RecordingIndicatorPref.swift
//  OpenPrompter
//
//  How the user wants to be told they're recording. Three choices — Live
//  Activity (Dynamic Island) only, both, or tally light only. Default on
//  Dynamic-Island-capable devices is "both" (belt-and-suspenders), per
//  V2 Design 02 review note 6.
//
//  On non-island devices, only `tallyOnly` is selectable — the Live Activity
//  presentations require an Always-On display island to be useful and the
//  setting view greys out the other two rows.
//

import ActivityKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum RecordingIndicatorPref: String, CaseIterable, Codable, Hashable, Sendable {
    /// Show the Dynamic Island Live Activity only — no in-app tally light.
    /// User wants the discreet presentation; the system-blessed surface is
    /// enough.
    case islandOnly

    /// Both presentations on simultaneously. Live Activity for cross-app
    /// visibility, tally-light border for unmissable peripheral cue while
    /// the prompter is foregrounded. Default on island devices.
    case both

    /// Tally-light only — the original Feature 1 indicator. The default on
    /// non-island devices and the only option exposed there.
    case tallyOnly

    /// Default for the running device. Returns `.both` on Dynamic Island
    /// devices and `.tallyOnly` everywhere else. Read once on first launch
    /// and persisted to `Prefs.recordingIndicator`; subsequent launches read
    /// the persisted value.
    static var `default`: RecordingIndicatorPref {
        if Self.deviceSupportsLiveActivity {
            return .both
        } else {
            return .tallyOnly
        }
    }

    /// True when the running OS + device combo supports ActivityKit Live
    /// Activities. iOS 16.1+ is the version gate; the device-class check
    /// is conservative — ActivityKit reports `areActivitiesEnabled` as the
    /// authoritative answer at runtime, but we use it as a default seeder
    /// so a cold-launch picker doesn't show choices the user can't pick.
    static var deviceSupportsLiveActivity: Bool {
        // ActivityKit explicitly tells us if activities are usable on this
        // device + user-settings combination. This is the canonical signal.
        if #available(iOS 16.2, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled
        }
        return false
    }

    /// Picker label.
    var displayName: String {
        switch self {
        case .islandOnly: return "dynamic island only"
        case .both:       return "both dynamic island and tally light"
        case .tallyOnly:  return "tally light only"
        }
    }

    /// True when the in-app tally-light overlay should render in the
    /// recording phase. (Consumed by `TallyLightOverlay`.)
    var showsTallyLight: Bool {
        switch self {
        case .both, .tallyOnly: return true
        case .islandOnly:       return false
        }
    }

    /// True when the Live Activity should be requested when entering the
    /// recording phase. (Consumed by `RecordingSession`.)
    var showsLiveActivity: Bool {
        switch self {
        case .both, .islandOnly: return true
        case .tallyOnly:         return false
        }
    }
}

//
//  RecordingCountdown.swift
//  OpenPrompter
//
//  Pre-roll countdown duration. 0 / 3 / 5 — same options as the cinematic
//  retake-board pattern.  3 is the default per V2 Design 02 review note 2.
//

import Foundation

enum RecordingCountdown: String, CaseIterable, Codable, Hashable, Sendable {
    case off
    case three
    case five

    static var `default`: RecordingCountdown { .three }

    /// Number of seconds to count down before recording starts. `0` means
    /// no pre-roll — the writer starts immediately on REC tap.
    var seconds: Int {
        switch self {
        case .off:   return 0
        case .three: return 3
        case .five:  return 5
        }
    }

    /// Picker label.
    var displayName: String {
        switch self {
        case .off:   return "off (immediate)"
        case .three: return "3 seconds"
        case .five:  return "5 seconds"
        }
    }
}

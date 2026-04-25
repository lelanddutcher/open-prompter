//
//  RecordingPhase.swift
//  OpenPrompter
//
//  The recording state machine, codified as an enum so transitions are
//  exhaustive and the compiler keeps every callsite honest. See
//  V2 Design 02 §"State machine".
//
//      idle ── tap rec ──► countdown(3) → countdown(2) → countdown(1)
//                                                              │
//                                                              ▼
//                                                          recording
//                                                              │
//        cancel during countdown ──► idle                      │
//                                                              ▼
//                                                          finalizing
//                                                              │
//                                                              ▼
//                                                          saving
//                                                              │
//                                                              ▼
//                                                          idle (toast)
//                                                              │
//                                                  failure ────► error
//
//  We intentionally do NOT collapse `finalizing` and `saving` into one phase.
//  `finalizing` covers `AVAssetWriter.finishWriting`; `saving` covers the
//  Photos write + optional iCloud copy. Treating them separately lets the
//  chip surface two distinct labels (a "finalizing" indeterminate spinner,
//  then a "saving" label) and lets the Live Activity update its presentation
//  to "saving" without faking a phase transition through a recording state.
//

import Foundation

/// All possible states of the recording feature. Equatable so SwiftUI can
/// react to transitions; `Sendable` so the @MainActor model can hand the
/// value off to the Live Activity actor without further hoops.
///
/// Codable round-trips the simpler cases. The Live Activity ContentState type
/// uses `RecordingPhase.simpleKey` to encode the phase as a stable string,
/// not the associated values — start time and error messages don't need to
/// travel through the activity payload.
enum RecordingPhase: Equatable, Sendable {
    /// No recording in flight. The chip shows the red REC dot.
    case idle

    /// Pre-roll countdown is running. `remaining` counts down 3 → 2 → 1.
    /// Cancellable via tap-anywhere or via a hardware-button press.
    case countdown(remaining: Int)

    /// Active recording. `startedAt` is captured when the writer begins so
    /// the elapsed-time label and the Live Activity timer agree.
    case recording(startedAt: Date)

    /// `AVAssetWriter.finishWriting` is in flight. Typically <2 seconds.
    case finalizing

    /// Photos write + optional iCloud-next-to-script copy is running. The
    /// `destinations` value records what the user asked for so the chip can
    /// label progress accordingly.
    case saving(destinations: SaveDestinations)

    /// A non-recoverable failure occurred. Holds a user-readable message
    /// surfaced via the banner. The chip resets to idle once the user
    /// dismisses the banner or after the auto-dismiss timeout.
    case error(String)
}

/// Which save destinations the user picked at the start of the take. Captured
/// at start-of-recording (not at save time) so a Settings flip mid-take
/// doesn't change the destination list partway through.
struct SaveDestinations: Equatable, Sendable {
    /// Photos library is the always-on default.
    var photos: Bool = true
    /// Optional iCloud-next-to-script copy. Mirrors the
    /// `pref.recording.saveToScriptFolder` toggle.
    var scriptFolder: Bool = false

    static let `default` = SaveDestinations(photos: true, scriptFolder: false)
}

extension RecordingPhase {
    /// True when the prompter is actively writing camera frames to disk.
    /// Drives `RecordingState.isRecording` so the existing tally-light
    /// wiring continues to work without callsite changes.
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    /// Stable identifier for cross-process serialization (Live Activity
    /// payload). Renaming any of these keys breaks running activities — keep
    /// stable across releases or write a migration in the activity widget.
    var simpleKey: String {
        switch self {
        case .idle:        return "idle"
        case .countdown:   return "countdown"
        case .recording:   return "recording"
        case .finalizing:  return "finalizing"
        case .saving:      return "saving"
        case .error:       return "error"
        }
    }

    /// Lightweight Codable shape used by tests to round-trip the simpler
    /// cases (idle / finalizing / countdown / recording). The error-string
    /// payload is preserved verbatim.
    enum CodableShape: Codable, Equatable, Sendable {
        case idle
        case countdown(Int)
        case recording(Date)
        case finalizing
        case saving(Bool, Bool) // photos, scriptFolder
        case error(String)
    }

    var codableShape: CodableShape {
        switch self {
        case .idle:                       return .idle
        case .countdown(let n):           return .countdown(n)
        case .recording(let started):     return .recording(started)
        case .finalizing:                 return .finalizing
        case .saving(let dests):          return .saving(dests.photos, dests.scriptFolder)
        case .error(let msg):             return .error(msg)
        }
    }

    init(_ shape: CodableShape) {
        switch shape {
        case .idle:                                self = .idle
        case .countdown(let n):                    self = .countdown(remaining: n)
        case .recording(let d):                    self = .recording(startedAt: d)
        case .finalizing:                          self = .finalizing
        case .saving(let p, let s):                self = .saving(destinations: SaveDestinations(photos: p, scriptFolder: s))
        case .error(let msg):                      self = .error(msg)
        }
    }
}

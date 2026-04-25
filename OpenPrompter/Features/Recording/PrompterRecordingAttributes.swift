//
//  PrompterRecordingAttributes.swift
//  OpenPrompter (and OpenPrompterLiveActivity)
//
//  Shared ActivityAttributes for the Live Activity. Consumed by both the
//  main app target (which calls `Activity.request(...)` / `update(...)` /
//  `end(...)` via `RecordingSession`) and the widget extension target
//  (which renders the compact / expanded / lock-screen presentations).
//
//  The struct must be identical between targets. It lives in the main
//  app source tree and is referenced by the widget extension's sources
//  list in `project.yml` so XcodeGen materializes it into both build
//  graphs without duplication.
//

import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// Live Activity attributes for the recording feature. The static
/// `scriptID` is captured at start-of-take and used only as a debug
/// breadcrumb (it lets developers correlate a Live Activity with a
/// specific script across logs).
public struct PrompterRecordingAttributes: ActivityAttributes {
    public typealias ContentState = PrompterRecordingState

    /// Script-stable identifier — typically the script's URL string. Used
    /// as a debug correlation key. Not displayed.
    public let scriptID: String

    public init(scriptID: String) {
        self.scriptID = scriptID
    }

    /// Mutable per-update content. The widget reads this to render every
    /// presentation.
    public struct PrompterRecordingState: Codable, Hashable {
        /// Countdown remaining seconds (or `0` outside the countdown phase).
        /// Used only by the countdown numeral. The running clock is driven
        /// by `startedAt` + `Text(date, style: .timer)` so the system
        /// updates the displayed time without per-second `Activity.update`s
        /// (V2 Design 02 review note 4).
        public var elapsedSeconds: Int
        /// Wall-clock moment recording began (or last resumed). Set when
        /// the session transitions countdown → recording, then read by
        /// the widget via `Text(startedAt, style: .timer)`.
        /// `Date.distantPast` for non-recording phases (the widget gates on
        /// `phase == "recording"` before rendering the timer).
        public var startedAt: Date
        /// Truncated script title for the expanded / lock-screen
        /// presentations. Empty string when the user is on the demo or no
        /// script is loaded.
        public var scriptTitle: String
        /// Phase identifier — `"countdown"`, `"recording"`, `"finalizing"`,
        /// or `"idle"` (when the activity is being torn down).
        public var phase: String

        public init(
            elapsedSeconds: Int,
            startedAt: Date = .distantPast,
            scriptTitle: String,
            phase: String
        ) {
            self.elapsedSeconds = elapsedSeconds
            self.startedAt = startedAt
            self.scriptTitle = scriptTitle
            self.phase = phase
        }
    }
}

#endif

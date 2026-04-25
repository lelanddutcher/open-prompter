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
        /// Wall-clock seconds since the writer started. The widget can
        /// either render this directly or use it as a fallback when the
        /// system-managed `ActivityViewContextDate` form isn't available.
        public var elapsedSeconds: Int
        /// Truncated script title for the expanded / lock-screen
        /// presentations. Empty string when the user is on the demo or no
        /// script is loaded.
        public var scriptTitle: String
        /// Phase identifier — `"countdown"`, `"recording"`, `"finalizing"`,
        /// or `"idle"` (when the activity is being torn down).
        public var phase: String

        public init(elapsedSeconds: Int, scriptTitle: String, phase: String) {
            self.elapsedSeconds = elapsedSeconds
            self.scriptTitle = scriptTitle
            self.phase = phase
        }
    }
}

#endif

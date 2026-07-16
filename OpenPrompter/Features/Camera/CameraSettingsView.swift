//
//  CameraSettingsView.swift
//  OpenPrompter
//
//  Settings section for the camera composition feature (V2 Design 01 §
//  "Settings entries"). Lives in `SettingsView` between Mirror and Labs.
//
//  Shown when EITHER the Labs flag is on OR the user has already picked a
//  non-`.off` mode. This keeps the setting hidden from users who never opted
//  in until they do, but doesn't strand a setting they're already using.
//
//  Pickers dropped over successive dogfood passes:
//  - "default camera" (front/rear) — the camera is now selfie-only
//  - "pip starting corner" — the tile is free-positioned; corners gone
//  - "style" (pip / behind / off) — REMOVED in v3. The app only supports
//    picture-in-picture; "behind" was already gone (routes to `.off`), so
//    the picker offered no real choice. The camera is turned on/off via the
//    in-prompter chip (off↔pip); there is no user-facing STYLE choice. The
//    `CameraStyle.behind` enum case is kept elsewhere for downgrade safety.
//

import SwiftUI

struct CameraSettingsView: View {
    // @AppStorage so the picker self-heals when the user touches the same
    // pref from outside Settings (e.g. via the chip in the prompter).
    @AppStorage(PrefKey.cameraPipSize.rawValue) private var pipSizeRaw: String = "medium"

    /// Recording-state model. Optional — Settings doesn't need a real
    /// `RecordingState` to render the toggle UI; callers wire the actual
    /// flag inside the prompter. When supplied, the toggle binds directly
    /// to `state.isRecording` (the type is `@Observable`) so no local
    /// mirror state is needed.
    @Bindable private var recordingStateOrPlaceholder: RecordingState
    private let hasRecordingState: Bool

    init(recordingState: RecordingState? = nil) {
        self.recordingStateOrPlaceholder = recordingState ?? RecordingState()
        self.hasRecordingState = recordingState != nil
    }

    var body: some View {
        Group {
            Section("camera") {
                Picker("pip starting size", selection: $pipSizeRaw) {
                    ForEach(PipSize.allCases, id: \.rawValue) { size in
                        Text(size.displayName).tag(size.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text("the tile remembers wherever you last dropped it on screen.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)

                #if DEBUG
                if hasRecordingState {
                    Toggle(
                        "debug: force tally light on",
                        isOn: $recordingStateOrPlaceholder.isRecording
                    )
                    Text("flips the recording-state flag for design validation. real recording arrives in feature 2.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                }
                #endif
            }
        }
    }
}

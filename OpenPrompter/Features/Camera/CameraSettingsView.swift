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
//  After the post-merge dogfood pass we dropped two pickers:
//  - "default camera" (front/rear) — the camera is now selfie-only
//  - "pip starting corner" — the tile is free-positioned; corners gone
//

import SwiftUI

struct CameraSettingsView: View {
    // @AppStorage so the pickers self-heal when the user touches the same
    // prefs from outside Settings (e.g. via the chip in the prompter).
    @AppStorage(PrefKey.cameraStyle.rawValue) private var styleRaw: String = "off"
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
                Picker("style", selection: $styleRaw) {
                    ForEach(CameraStyle.allCases, id: \.rawValue) { style in
                        Text(style.settingsDisplayName).tag(style.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text("picture-in-picture floats a small camera tile over the prompter. behind text fills the screen with the camera and overlays the script.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)

                Picker("pip starting size", selection: $pipSizeRaw) {
                    ForEach(PipSize.allCases, id: \.rawValue) { size in
                        Text(size.displayName).tag(size.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text("the tile remembers wherever you last dropped it on screen.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)

                if hasRecordingState {
                    Toggle(
                        "debug: force tally light on",
                        isOn: $recordingStateOrPlaceholder.isRecording
                    )
                    Text("flips the recording-state flag for design validation. real recording arrives in feature 2.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                }
            }
        }
    }
}

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

import SwiftUI

struct CameraSettingsView: View {
    @State private var styleRaw: String = Prefs.cameraStyle
    @State private var facingFront: Bool = Prefs.cameraFacingFront
    @State private var pipSizeRaw: String = Prefs.cameraPipSize
    @State private var pipCornerRaw: String = Prefs.cameraPipCornerLast
    @State private var debugTallyOn: Bool

    /// Recording-state model. Optional — Settings doesn't need a real
    /// `RecordingState` to render the toggle UI (it just toggles the local
    /// `debugTallyOn`); callers wire the actual flag inside the prompter.
    private let recordingState: RecordingState?

    init(recordingState: RecordingState? = nil) {
        self.recordingState = recordingState
        _debugTallyOn = State(initialValue: recordingState?.isRecording ?? false)
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
                .onChange(of: styleRaw) { _, new in
                    Prefs.cameraStyle = new
                }
                Text("picture-in-picture floats a small camera tile over the prompter. behind text fills the screen with the camera and overlays the script.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)

                Picker("default camera", selection: Binding(
                    get: { facingFront },
                    set: { newValue in
                        facingFront = newValue
                        Prefs.cameraFacingFront = newValue
                    }
                )) {
                    Text("front").tag(true)
                    Text("rear").tag(false)
                }
                .pickerStyle(.menu)

                Picker("pip starting size", selection: $pipSizeRaw) {
                    ForEach(PipSize.allCases, id: \.rawValue) { size in
                        Text(size.displayName).tag(size.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: pipSizeRaw) { _, new in
                    Prefs.cameraPipSize = new
                }

                Picker("pip starting corner", selection: $pipCornerRaw) {
                    ForEach(PipCorner.allCases, id: \.rawValue) { corner in
                        Text(corner.displayName).tag(corner.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: pipCornerRaw) { _, new in
                    Prefs.cameraPipCornerLast = new
                }
                Text("the tile remembers wherever you last dropped it; this is the first-launch default.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)

                if let state = recordingState {
                    Toggle("debug: force tally light on", isOn: Binding(
                        get: { state.isRecording },
                        set: { newValue in
                            // Sync both directions so the local @State view
                            // updates if the toggle is hit elsewhere.
                            if newValue != state.isRecording {
                                state.isRecording = newValue
                            }
                            debugTallyOn = newValue
                        }
                    ))
                    Text("flips the recording-state flag for design validation. real recording arrives in feature 2.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                }
            }
        }
    }
}

//
//  CaptureSettingsView.swift
//  OpenPrompter
//
//  "Camera & recording" drill-down of the Settings overhaul (V3 Sprint item
//  2). A THIN wrapper — it composes the existing, unchanged `CameraSettingsView`
//  and `RecordingSettingsView` behind one `Form`. Their contents are NOT
//  edited here (they render bare `Section`s inside a `Group`, so this view
//  supplies the surrounding `Form` + navigation title).
//
//  Gating mirrors the old flat `SettingsView` exactly so nothing surfaces
//  that wasn't visible before:
//    - Camera section: `labs.cameraStyle` on OR a non-`.off` camera style.
//    - Recording section: `labs.recording` on.
//
//  The home index only offers this drill-down when at least one of those
//  gates (or a non-`.off` style) is satisfied, but we re-check each gate here
//  so the two sections stay independent — e.g. a user with Recording Labs off
//  but PiP on sees only the camera section, exactly as before.
//
//  IMPORTANT: `RecordingSettingsView`'s "current source" row reflects what iOS
//  is picking up right now, which requires the route monitor to be running.
//  Settings opens from the library — outside any prompter session — so the
//  monitor is started here in `.onAppear`, preserving the flat view's
//  behaviour.
//

import SwiftUI

struct CaptureSettingsView: View {
    @Environment(AppState.self) private var appState

    @AppStorage(PrefKey.labsCameraStyle.rawValue) private var labsCameraStyle: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()
    @AppStorage(PrefKey.labsRecording.rawValue) private var labsRecording: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()
    @AppStorage(PrefKey.cameraStyle.rawValue) private var cameraStyleRaw: String = "off"

    var body: some View {
        Form {
            // Camera Style + PiP (V2 Feature 1). Visible when EITHER the Labs
            // flag is on OR the user already picked a non-`.off` style — so a
            // user who turned on PiP via the chip never loses the entry, even
            // if a future build flips Labs off.
            if labsCameraStyle || cameraStyleRaw != "off" {
                CameraSettingsView(recordingState: appState.recordingState)
            }

            // Recording (Features 2 + 4). Behind the labs flag.
            if labsRecording {
                RecordingSettingsView(routeMonitor: appState.audioRouteMonitor)
            }
        }
        .padListWidth()
        .frame(maxWidth: .infinity)
        .navigationTitle("camera & recording")
        .navigationBarTitleDisplayMode(.inline)
        // The route monitor must be running for the recording "current source"
        // row to reflect the live route. Started here because Settings opens
        // outside a prompter session. (Preserved from the flat SettingsView.)
        .onAppear { appState.audioRouteMonitor.start() }
    }
}

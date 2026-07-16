//
//  SettingsView.swift
//  OpenPrompter
//
//  Presentation entry point for Settings. As of the V3 Sprint item-2 overhaul
//  the flat single-`Form` implementation moved to `SettingsHomeView` (a
//  grouped drill-down). This type stays as a thin wrapper so the library's
//  presentation site (`LibraryView` → `.sheet { SettingsView() }`) needs no
//  change and the public entry point keeps its familiar name.
//
//  There is no state or logic here — everything lives in `SettingsHomeView`
//  and the five focused sub-views (`ReadingSettingsView`,
//  `CaptureSettingsView`, `RemoteControlSettingsView`, `AboutSettingsView`,
//  `LabsSettingsView`).
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        SettingsHomeView()
    }
}

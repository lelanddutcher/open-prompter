//
//  SettingsHomeView.swift
//  OpenPrompter
//
//  Top-level Settings index (V3 Sprint item 2). The old flat single-`Form`
//  `SettingsView` grew to ~10-11 sections once the batch-1 / wave-1 Labs
//  flags landed; this splits it into a grouped drill-down. Each destination
//  is a focused sub-view; NOTHING is dropped, and NO `PrefKey` changes — it
//  is pure view re-composition, so every sub-view keeps using
//  `@AppStorage(PrefKey.*.rawValue)` and self-heals.
//
//  Layout (per the sprint spec):
//    settings
//    ├── Reading            → ReadingSettingsView
//    ├── Camera & recording → CaptureSettingsView   (gated)
//    ├── Bluetooth remote   → RemoteControlSettingsView (gated, reused)
//    ├── About              → AboutSettingsView
//    └── Labs               → LabsSettingsView
//
//  Gating decisions match the old flat view exactly:
//    - Camera & recording surfaces when `labs.cameraStyle` OR `labs.recording`
//      is on, OR the user already picked a non-`.off` camera style (so a user
//      who enabled PiP via the chip never loses the entry).
//    - Bluetooth remote surfaces when `labs.bluetoothRemote` is on.
//    - Reading / About / Labs are always visible.
//
//  `SettingsView` (the name the library presents) is kept as a thin wrapper
//  around this type so the presentation site needs no change.
//

import SwiftUI

struct SettingsHomeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    /// Labs flags gate in-progress features. DEBUG-on / Release-off, matching
    /// the per-build defaults the flat view used. Read here so the home index
    /// can decide which drill-down rows to show; the actual toggles live in
    /// `LabsSettingsView`.
    @AppStorage(PrefKey.labsBluetoothRemote.rawValue) private var labsBluetoothRemote: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()
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

    /// Read live so the Camera & recording row stays reachable once the user
    /// has picked a non-`.off` mode, regardless of the Labs flag.
    @AppStorage(PrefKey.cameraStyle.rawValue) private var cameraStyleRaw: String = "off"

    /// Whether the Camera & recording drill-down should be offered. Mirrors
    /// the flat view's dual gate: any of the two Labs flags, or an active
    /// camera style the user opted into.
    private var showCaptureRow: Bool {
        Self.shouldShowCaptureRow(
            labsCameraStyle: labsCameraStyle,
            labsRecording: labsRecording,
            cameraStyleRaw: cameraStyleRaw
        )
    }

    /// Pure gate for the Camera & recording drill-down row, extracted so the
    /// truth table is unit-testable without standing up SwiftUI + `@AppStorage`.
    /// Must stay identical to the union of the flat view's per-section gates:
    /// the camera section showed for `labsCameraStyle || style != off`, and the
    /// recording section for `labsRecording`; offering the drill-down when ANY
    /// of those would have surfaced keeps every setting reachable.
    static func shouldShowCaptureRow(
        labsCameraStyle: Bool,
        labsRecording: Bool,
        cameraStyleRaw: String
    ) -> Bool {
        labsCameraStyle || labsRecording || cameraStyleRaw != "off"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ReadingSettingsView()
                    } label: {
                        settingsRow(
                            title: "reading",
                            subtitle: "defaults, prompter font, mirror, parsing, appearance",
                            systemImage: "text.alignleft"
                        )
                    }

                    if showCaptureRow {
                        NavigationLink {
                            CaptureSettingsView()
                        } label: {
                            settingsRow(
                                title: "camera & recording",
                                subtitle: "picture-in-picture, quality, framerate, mic, save destinations",
                                systemImage: "camera"
                            )
                        }
                    }

                    if labsBluetoothRemote {
                        NavigationLink {
                            // Reused unchanged; wrapped in a Form + title here
                            // since it renders bare `Section`s.
                            Form {
                                RemoteControlSettingsView(
                                    bindings: appState.remoteBindings,
                                    monitor: appState.keyboardMonitor
                                )
                            }
                            .navigationTitle("bluetooth remote")
                            .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            settingsRow(
                                title: "bluetooth remote",
                                subtitle: "keyboard, presenter, and media-key control with remappable bindings",
                                systemImage: "keyboard"
                            )
                        }
                    }
                }

                Section {
                    NavigationLink {
                        AboutSettingsView()
                    } label: {
                        settingsRow(
                            title: "about",
                            subtitle: "version, source, privacy, support the project",
                            systemImage: "info.circle"
                        )
                    }

                    NavigationLink {
                        LabsSettingsView()
                    } label: {
                        settingsRow(
                            title: "labs",
                            subtitle: "opt-in toggles for in-progress features",
                            systemImage: "flask"
                        )
                    }
                }
            }
            .navigationTitle("settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// A drill-down index row: icon + title over a one-line summary. Kept
    /// local so all five rows stay visually consistent.
    @ViewBuilder
    private func settingsRow(
        title: String,
        subtitle: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(.vertical, 2)
    }
}

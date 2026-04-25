//
//  RemoteControlSettingsView.swift
//  OpenPrompter
//
//  The "Remote Control" Settings section (Feature 7). Behind the
//  `labs.bluetoothRemote` flag in `SettingsView`. Master toggle, volume opt-in
//  with App-Store-cautious copy, list of bindings with per-row Picker for
//  the bound action, "Press any key to bind" capture sheet, reset to
//  defaults, and a connection chip for keyboard presence.
//
//  Why a separate file: the bindings list grows with the event vocabulary
//  and the capture sheet has nontrivial focus glue. Keeping it here keeps
//  SettingsView readable as the central index of what's tunable.
//

import SwiftUI

struct RemoteControlSettingsView: View {
    @Environment(AppState.self) private var appState
    @Bindable private var bindings: RemoteBindingStore
    private let monitor: KeyboardConnectionMonitor

    @AppStorage(PrefKey.remoteEnabled.rawValue) private var remoteEnabled: Bool = true
    @AppStorage(PrefKey.useVolumeButtons.rawValue) private var useVolumeButtons: Bool = false

    @State private var captureKey: RemoteKey?
    @State private var showResetConfirm: Bool = false

    init(bindings: RemoteBindingStore, monitor: KeyboardConnectionMonitor) {
        self.bindings = bindings
        self.monitor = monitor
    }

    var body: some View {
        Group {
            Section("remote control") {
                Toggle("bluetooth remote", isOn: $remoteEnabled)
                Text("use a paired bluetooth keyboard, presenter, or media remote to drive the prompter. on by default — bindings below.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)

                HStack(spacing: 8) {
                    Circle()
                        .fill(monitor.isKeyboardConnected ? Theme.green : Theme.ghost)
                        .frame(width: 8, height: 8)
                    Text(monitor.isKeyboardConnected
                         ? "keyboard connected"
                         : "no keyboard detected")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                    Spacer()
                }

                Toggle("use volume buttons", isOn: $useVolumeButtons)
                    .disabled(!remoteEnabled)
                Text("use volume buttons to control prompter. disables volume adjustment inside the prompter while active. some cheap clickers (AB Shutter 3) only emit volume up — turn this on if your remote isn't otherwise detected. off by default.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)

                Text("voiceover intercepts arrow keys before the app sees them, so some shortcuts won't fire while voiceover is on. keyboard, space, and return still work.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
            }

            Section("bindings") {
                ForEach(visibleBindings, id: \.key.id) { entry in
                    bindingRow(for: entry.key, currentEvent: entry.event)
                }
                .disabled(!remoteEnabled)

                Button {
                    showResetConfirm = true
                } label: {
                    Label("reset to defaults", systemImage: "arrow.counterclockwise")
                }
                .disabled(!remoteEnabled)

                Text("tap a row to remap. each key can map to one action, or unbind it.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
            }
        }
        .sheet(item: $captureKey) { key in
            RemoteCaptureSheet(
                bindings: bindings,
                editingKey: key,
                isPresented: Binding(
                    get: { captureKey != nil },
                    set: { if !$0 { captureKey = nil } }
                )
            )
        }
        .confirmationDialog(
            "reset all remote bindings?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("reset", role: .destructive) {
                bindings.resetToDefaults()
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("restores every key to its default action.")
        }
    }

    /// All current bindings, with volume keys filtered out unless the
    /// volume opt-in is active. Sorted for stable display.
    private var visibleBindings: [(key: RemoteKey, event: RemoteEvent)] {
        bindings.allBindings.filter { entry in
            if entry.key.requiresVolumeOptIn {
                return useVolumeButtons
            }
            return true
        }
    }

    @ViewBuilder
    private func bindingRow(for key: RemoteKey, currentEvent: RemoteEvent) -> some View {
        HStack(spacing: 12) {
            Text(key.displayName)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            Picker("", selection: Binding(
                get: { currentEvent },
                set: { newEvent in
                    bindings.setBinding(newEvent, for: key)
                }
            )) {
                ForEach(RemoteEvent.allCases, id: \.self) { event in
                    Text(event.displayName).tag(event)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }
}

/// Modal "press any key to bind" capture sheet. Reuses
/// `KeyboardEventSource.remoteKey(from:)` to translate the SwiftUI press
/// into a `RemoteKey`, then writes the binding into the store.
///
/// We do NOT prompt the user to actually press a key when there's no
/// connected keyboard — the inline picker in `RemoteControlSettingsView`
/// covers that path. This sheet is reserved for the (future) "+" affordance
/// that captures a brand-new key not in the default table.
struct RemoteCaptureSheet: View {
    @Bindable var bindings: RemoteBindingStore
    let editingKey: RemoteKey
    @Binding var isPresented: Bool

    @State private var selected: RemoteEvent
    @FocusState private var captureFocused: Bool
    @State private var captureMessage: String = "press any key…"

    init(
        bindings: RemoteBindingStore,
        editingKey: RemoteKey,
        isPresented: Binding<Bool>
    ) {
        self.bindings = bindings
        self.editingKey = editingKey
        self._isPresented = isPresented
        // Seed the picker with the current binding so a "Done" without a
        // key press leaves the system in a consistent state.
        let initial = bindings.event(for: editingKey) ?? .playPause
        _selected = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("editing") {
                    Text(editingKey.displayName)
                        .font(.system(size: 18, weight: .bold))
                }

                Section("action") {
                    Picker("action", selection: $selected) {
                        ForEach(RemoteEvent.allCases, id: \.self) { event in
                            Text(event.displayName).tag(event)
                        }
                    }
                    .pickerStyle(.inline)
                }

                Section("press any key") {
                    Text(captureMessage)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                }
                .focusable()
                .focused($captureFocused)
                .focusEffectDisabled()
                .onKeyPress(phases: .down) { press in
                    if let key = KeyboardEventSource.remoteKey(from: press) {
                        bindings.setBinding(selected, for: key)
                        captureMessage = "bound \(key.displayName) → \(selected.displayName)"
                    } else {
                        captureMessage = "key not recognized — try a different one"
                    }
                    return .handled
                }
            }
            .navigationTitle("remap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done") {
                        bindings.setBinding(selected, for: editingKey)
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("cancel") { isPresented = false }
                }
            }
            .task {
                captureFocused = true
            }
        }
    }
}

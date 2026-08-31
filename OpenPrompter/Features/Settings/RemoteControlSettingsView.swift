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

    @State private var showResetConfirm: Bool = false

    /// The ONE sheet this view presents at a time.
    ///
    /// ╭──────────────── FIX — wizard "collapses on open" ──────────────────╮
    /// │ The view previously attached TWO `.sheet` modifiers (`$captureKey`  │
    /// │ + `$showWizard`) AND a `.confirmationDialog` to the outer `Group`   │
    /// │ of `Section`s. SwiftUI applies a modifier placed on a `Group` to    │
    /// │ EACH member, so those presentations were replicated across every    │
    /// │ section — tapping "learn your remote" fired several competing sheet │
    /// │ presentations bound to the same state, which immediately tore each  │
    /// │ other down (the sheet appeared and collapsed with no input). Now    │
    /// │ there is a SINGLE `.sheet(item:)`, attached to a single leaf view   │
    /// │ (the wizard button), and the reset dialog hangs off its own button. │
    /// ╰─────────────────────────────────────────────────────────────────────╯
    private enum ActiveRemoteSheet: Identifiable {
        /// The guided "learn your remote" wizard.
        case wizard
        /// The single-key remap sheet (reserved for a future "+/edit"
        /// affordance — nothing sets it yet, same reachability as the old
        /// `captureKey`, but now it can never conflict with the wizard).
        case remap(RemoteKey)

        var id: String {
            switch self {
            case .wizard:       return "wizard"
            case .remap(let k): return "remap.\(k.id)"
            }
        }
    }

    @State private var activeSheet: ActiveRemoteSheet?

    init(bindings: RemoteBindingStore, monitor: KeyboardConnectionMonitor) {
        self.bindings = bindings
        self.monitor = monitor
    }

    /// Bridges the `item`-based sheet host to the `Binding<Bool>` the wizard /
    /// remap sheets expect: setting it false (finish / cancel / done) clears
    /// `activeSheet`, dismissing the single sheet.
    private var sheetDismissBinding: Binding<Bool> {
        Binding(
            get: { activeSheet != nil },
            set: { if !$0 { activeSheet = nil } }
        )
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
                        .fill(monitor.isRemoteDetected ? Theme.green : Theme.ghost)
                        .frame(width: 8, height: 8)
                    // Honest chip (audit fix 5 / D5): a connected pointer
                    // (GCMouse — the BLE-M5 D-pad) OR any actual event from a
                    // keyboard / media / volume remote all count as "detected."
                    // The old copy said "no keyboard" for a working Satechi R2
                    // / AB-Shutter / BLE-M5.
                    Text(monitor.isRemoteDetected
                         ? "remote detected"
                         : "no remote detected")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                    Spacer()
                }
                // Refresh GameController presence so a remote paired BEFORE this
                // screen opened is reflected without waiting for a notification.
                .onAppear { monitor.refreshConnectedDevices() }

                #if DEBUG
                // On-screen signal breakdown so the founder can see EXACTLY
                // what is (or isn't) driving the chip on the device: pointer /
                // keyboard presence via GameController, plus whether any real
                // event has reached the app. Makes "no remote detected"
                // diagnosable instead of a mystery.
                Text("diag · pointer(GCMouse): \(monitor.isMouseConnected ? "yes" : "no") · keyboard(GCKeyboard): \(monitor.isKeyboardConnected ? "yes" : "no") · event-seen: \(monitor.hasSeenRemoteEvent ? "yes" : "no")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                #endif

                Toggle("use volume buttons", isOn: $useVolumeButtons)
                    .disabled(!remoteEnabled)
                Text("use volume buttons to control prompter. disables volume adjustment inside the prompter while active. some cheap clickers (AB Shutter 3) only emit volume up — turn this on if your remote isn't otherwise detected. off by default.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)

                Text("voiceover intercepts arrow keys before the app sees them, so some shortcuts won't fire while voiceover is on. keyboard, space, and return still work.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
            }

            // "Learn your remote" WIZARD (v3) — the PROMINENT entry point,
            // above the advanced bindings. The founder decided "the wizard
            // decides everything": a guided flow presses through the core
            // actions and binds whatever button the user presses (from ANY
            // source), so a fresh remote is usable in a few presses without
            // reasoning about the table below.
            Section {
                Button {
                    activeSheet = .wizard
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Theme.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("learn your remote")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(Theme.fg)
                            Text("press each button when prompted — we bind it for you.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.dim)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.dim)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .disabled(!remoteEnabled)
                // The SINGLE sheet host for this view — attached to one leaf
                // (this button), never the multi-Section Group, so it can't be
                // replicated / collapsed (see `ActiveRemoteSheet`).
                .sheet(item: $activeSheet) { sheet in
                    switch sheet {
                    case .wizard:
                        RemoteWizardView(
                            bindings: bindings,
                            monitor: monitor,
                            isPresented: sheetDismissBinding
                        )
                    case .remap(let key):
                        RemoteCaptureSheet(
                            bindings: bindings,
                            editingKey: key,
                            isPresented: sheetDismissBinding
                        )
                    }
                }
            } footer: {
                Text("works with any paired remote. for a volume-button clicker (e.g. AB Shutter 3, BLE-M5 shutter), turn on 'use volume buttons' above first so the wizard can hear it.")
                    .font(.system(size: 12))
            }

            Section("advanced bindings") {
                ForEach(visibleKeys, id: \.id) { key in
                    bindingRow(for: key)
                }
                .disabled(!remoteEnabled)

                Button {
                    showResetConfirm = true
                } label: {
                    Label("reset to defaults", systemImage: "arrow.counterclockwise")
                }
                .disabled(!remoteEnabled)
                // Dialog on its own leaf (this button), not the Group — same
                // reason the sheet moved off the Group (see `ActiveRemoteSheet`).
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

                Text("tap a row to remap. each key can map to one action, or unbind it.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
            }

            #if DEBUG
            // "Learn my remote" capture tool (audit fix 3 / §5). DEBUG only —
            // the in-app analog of the macOS hidcap logger. Pair any BLE
            // clicker and SEE what it emits so unknown devices become
            // bindable. Read-only diagnostic.
            Section("labs — learn my remote") {
                NavigationLink {
                    RemoteInputCaptureView(
                        store: bindings,
                        monitor: monitor
                    )
                } label: {
                    Label("capture remote input", systemImage: "dot.radiowaves.left.and.right")
                }
                Text("live-shows what a paired remote emits (source · key · action). use it to figure out an unknown clicker, then remap above.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
            }
            #endif
        }
    }

    /// All supported binding rows, including known keys that are currently
    /// unbound. Extras from persisted/user-created bindings are appended so
    /// forward-compatible keys are not hidden.
    private var visibleKeys: [RemoteKey] {
        let base = RemoteBindingStore.configurableKeys.filter { key in
            if key.requiresVolumeOptIn {
                return useVolumeButtons
            }
            return true
        }
        let extras = bindings.allBindings
            .map(\.key)
            .filter { key in
                !base.contains(key) && (!key.requiresVolumeOptIn || useVolumeButtons)
            }
            .sorted { $0.id < $1.id }
        return base + extras
    }

    @ViewBuilder
    private func bindingRow(for key: RemoteKey) -> some View {
        HStack(spacing: 12) {
            Text(key.displayName)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            Picker("", selection: Binding(
                get: { bindings.event(for: key) },
                set: { newEvent in
                    bindings.setBinding(newEvent, for: key)
                }
            )) {
                Text("Unbound").tag(nil as RemoteEvent?)
                ForEach(RemoteEvent.allCases, id: \.self) { event in
                    Text(event.displayName).tag(Optional(event))
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
            .padListWidth()
            .frame(maxWidth: .infinity)
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

#if DEBUG

/// "Learn my remote" live capture (audit fix 3 / §5). DEBUG only.
///
/// Stands up a CAPTURE-ONLY event bus and its own keyboard / GameController /
/// mouse / media sources, each with an `onCapture` hook that records the raw
/// resolved `RemoteKey` into a `RemoteInputCaptureLog` BEFORE the binding
/// gate — so an unmapped remote still shows up. The sources publish onto the
/// capture bus (NOT the prompter's), so nothing here drives scroll; it's a
/// pure diagnostic. Pointer scroll travel (the BLE-M5 D-pad axes) has no
/// bindable key, so it's captured through the mouse source's dedicated
/// scroll hook.
///
/// Volume capture IS wired here — but ONLY when the caller passes
/// `useVolumeButtons == true` (the App Store 2.5.9 opt-in). This screen has no
/// live prompter session underneath it, so the volume source claiming the
/// shared audio session (`.ambientObservation`) is safe. Wiring it is what
/// makes the founder's BLE-M5 shutter (a Consumer volume button) show up in
/// the log at all; without it the "learn my remote" tool was blind to the one
/// button that actually works. When the opt-in is off, the copy points the
/// user at the toggle on the previous screen.
struct RemoteInputCaptureView: View {
    let store: RemoteBindingStore
    let monitor: KeyboardConnectionMonitor
    /// Whether the volume opt-in is active. Read LIVE from `@AppStorage` (NOT a
    /// constructor snapshot): an eager `NavigationLink` destination captures
    /// its init args when the row first renders, which can be BEFORE the user
    /// flips "use volume buttons" — leaving a stale `false` that silently
    /// skipped wiring the volume source (round-1 bug: HUD shows, nothing
    /// captured). Reading the pref here means the `.task` always sees the
    /// current value when the view actually appears. (2.5.9: the source is
    /// still wired ONLY when this is true.)
    @AppStorage(PrefKey.useVolumeButtons.rawValue) private var useVolumeButtons: Bool = false

    @State private var log = RemoteInputCaptureLog()
    @State private var captureBus = RemoteEventBus()
    @State private var keyboardSource: KeyboardEventSource?
    @State private var gcKeyboardSource: GameControllerKeyboardSource?
    @State private var mouseSource: GCMouseSource?
    @State private var mediaSource: MediaCommandSource?
    @State private var volumeSource: VolumeEventSource?
    @State private var volumeStatus: String?
    @State private var exportMessage: String?
    /// Live raw-pointer telemetry: incremented on EVERY GCMouse move (below the
    /// scroll-step threshold too), so the founder can see on-screen whether iOS
    /// delivers ANY pointer movement for the BLE-M5 D-pad — the conclusive
    /// answer to "is the D-pad even reaching the app as a mouse?"
    @State private var rawPointerCount: Int = 0
    @State private var lastRawDelta: String = "—"
    @FocusState private var captureFocused: Bool

    /// Millisecond-resolution timestamp for the live log — remote presses land
    /// fast, so seconds alone can't tell two D-pad taps apart.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        Form {
            Section("listening") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(monitor.isRemoteDetected ? Theme.green : Theme.ghost)
                        .frame(width: 8, height: 8)
                    Text(monitor.isRemoteDetected ? "remote detected" : "waiting for input…")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                    Spacer()
                }

                // Device-presence diagnostic. Tells the founder whether iOS
                // even SEES the remote's HID profiles via GameController — an
                // empty log with "pointer: no" means the D-pad isn't surfacing
                // as a GCMouse (so nothing CAN be captured), which is a
                // conclusive result rather than a mystery.
                Text("pointer (GCMouse): \(monitor.isMouseConnected ? "yes" : "no")  ·  keyboard (GCKeyboard): \(monitor.isKeyboardConnected ? "yes" : "no")  ·  event reached app: \(monitor.hasSeenRemoteEvent ? "yes" : "no")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.dim)

                // Raw pointer telemetry — proves whether iOS delivers ANY
                // GCMouse movement for the D-pad, independent of the scroll
                // threshold. If this stays 0 while pressing the D-pad, iOS
                // isn't routing the pointer to the app (a conclusive result).
                Text("raw pointer deltas: \(rawPointerCount)  ·  last (dx,dy): \(lastRawDelta)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(rawPointerCount > 0 ? Theme.green : Theme.dim)

                // Volume-listening status — the founder's BLE-M5 shutter is a
                // Consumer volume button, so this line is what explains whether
                // the ONE button we know works will register here.
                Text(useVolumeButtons
                     ? (volumeStatus ?? "volume listening: on — a shutter / volume button will register below.")
                     : "volume listening: OFF — turn on 'use volume buttons' on the previous screen to capture a shutter / volume clicker (e.g. the BLE-M5 shutter).")
                    .font(.system(size: 12))
                    .foregroundStyle(useVolumeButtons ? Theme.dim : Theme.muted)

                Text("press buttons on your paired remote. keyboard, presenter, media, pointer / d-pad, and (when opted in) volume remotes show up live below.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
            }
            .onAppear { monitor.refreshConnectedDevices() }

            Section {
                if log.entries.isEmpty {
                    Text("no input captured yet.")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                } else {
                    ForEach(log.entries) { entry in
                        captureRow(entry)
                    }
                }
            } header: {
                Text("captured (\(log.entries.count))")
            }

            Section {
                Button {
                    log.clear()
                    exportMessage = nil
                } label: {
                    Label("clear", systemImage: "trash")
                }
                Button {
                    if let url = log.exportJSON() {
                        exportMessage = "wrote \(url.lastPathComponent)"
                    } else {
                        exportMessage = "export failed"
                    }
                } label: {
                    Label("export JSON", systemImage: "square.and.arrow.up")
                }
                .disabled(log.entries.isEmpty)
                if let exportMessage {
                    Text(exportMessage)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
                Text("export writes Documents/RemoteCapture.json — pull it with devicectl for a reproducible fixture.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
            }
        }
        // Focus glue so the SwiftUI .onKeyPress fallback fires while the GC
        // sources also listen focus-free. Both feed the same log; the log's
        // cap + newest-first insert absorbs any duplicate.
        .focusable()
        .focused($captureFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            keyboardSource?.handle(press) ?? .ignored
        }
        .navigationTitle("learn my remote")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Record helper closures capture `log` + `store`.
            keyboardSource = KeyboardEventSource(
                bus: captureBus,
                store: store,
                onCapture: { key in log.recordKey(key, source: "keyboard", store: store) }
            )
            let gc = GameControllerKeyboardSource(
                bus: captureBus,
                store: store,
                onCapture: { key in log.recordKey(key, source: "keyboard", store: store) }
            )
            gcKeyboardSource = gc
            gc.start()

            let mouse = GCMouseSource(
                bus: captureBus,
                store: store,
                onCapture: { key in log.recordKey(key, source: "mouse", store: store) },
                onScrollCapture: { event in
                    log.recordEvent(event, source: "mouse", rawDescriptor: "pointer \(event.displayName)")
                },
                onRawPointer: { dx, dy in
                    rawPointerCount += 1
                    lastRawDelta = String(format: "%.1f, %.1f", Double(dx), Double(dy))
                }
            )
            mouseSource = mouse
            mouse.start()

            let media = MediaCommandSource(
                bus: captureBus,
                store: store,
                onCapture: { key in log.recordKey(key, source: "media", store: store) }
            )
            mediaSource = media
            media.start()

            // Volume KVO source — wired ONLY when the user has opted in (App
            // Store 2.5.9). This is what makes the founder's BLE-M5 shutter
            // (a Consumer volume button) visible in the log; without it the
            // "learn my remote" tool couldn't see the one button that works.
            if useVolumeButtons {
                let volume = VolumeEventSource(
                    bus: captureBus,
                    store: store,
                    onCapture: { key in log.recordKey(key, source: "volume", store: store) },
                    onActivationFailure: { message in volumeStatus = "volume listening: \(message)" }
                )
                volumeSource = volume
                volume.start()
            }

            // Latch the honest chip on the first captured event too.
            captureFocused = true
        }
        .task {
            // Drain the capture bus purely to note "we saw a remote event"
            // for the honest chip — the events do NOT drive any prompter.
            for await _ in captureBus.events {
                monitor.noteRemoteEvent()
            }
        }
        .onDisappear {
            gcKeyboardSource?.stop()
            mouseSource?.stop()
            mediaSource?.stop()
            volumeSource?.stop()
            captureFocused = false
        }
    }

    @ViewBuilder
    private func captureRow(_ entry: CapturedRemoteInput) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(entry.source.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                Text(entry.rawDescriptor)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
            HStack(spacing: 6) {
                Text(entry.resolvedRemoteKey ?? "unmapped key")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(entry.resolvedRemoteKey == nil ? Theme.dim : Theme.muted)
                Text("→")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                Text(entry.boundEvent.map { RemoteEvent(rawValue: $0)?.displayName ?? $0 } ?? "unbound")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(entry.boundEvent == nil ? Theme.dim : Theme.green)
            }
        }
        .padding(.vertical, 2)
    }
}

#endif

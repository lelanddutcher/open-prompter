//
//  RemoteWizardView.swift
//  OpenPrompter
//
//  "Learn your remote" WIZARD (v3 — "the wizard decides everything").
//
//  ╭──────────────────────────── WHAT THIS IS ──────────────────────────────╮
//  │ A friendly, guided front-end to the existing `RemoteBindingStore`. The  │
//  │ founder's remotes vary wildly (BLE-M5 shutter = volume button, D-pad =  │
//  │ Bluetooth trackpad; presenter clickers = arrows / media keys). Instead  │
//  │ of asking the user to reason about "which physical key maps to which    │
//  │ action" in the advanced table, the wizard walks the CORE actions in     │
//  │ order and, for each, says "press the button for <action>", captures the │
//  │ NEXT input from ANY source (keyboard / mouse / media / volume), shows    │
//  │ "detected: <source> · <key>", and writes the binding.                   │
//  │                                                                         │
//  │ It is ONLY a front-end: it reads and writes the same `RemoteBindingStore`│
//  │ the advanced bindings list edits. Nothing here is a parallel binding     │
//  │ system. Skip / redo per step; "Done" persists (the store autosaves on    │
//  │ each `setBinding`, so persistence is immediate — "Done" just dismisses). │
//  ╰────────────────────────────────────────────────────────────────────────╯
//
//  Capture mechanism (mirrors the DEBUG `RemoteInputCaptureView`): the wizard
//  stands up a CAPTURE-ONLY `RemoteEventBus` plus its own keyboard /
//  GameController-keyboard / mouse / media (and, when the volume opt-in is on,
//  volume) sources, each with an `onCapture` hook that hands the resolved
//  `RemoteKey` to the model BEFORE the binding gate — so a still-unmapped
//  button is captured. The sources publish onto the capture bus, NOT the
//  prompter's, so the wizard never drives scroll while learning.
//
//  Volume note (App Store 2.5.9): the volume KVO source is wired here ONLY
//  when the user has already flipped the "use volume buttons" opt-in. The
//  wizard never enables it implicitly.
//
//  Split: `RemoteWizardModel` owns the step progression, capture state, and
//  the binding writes — plain `@MainActor @Observable`, no SwiftUI, so the
//  capture→bind flow is unit-testable without standing up a view. The view is
//  a thin renderer over the model plus the live capture-source plumbing.
//

import SwiftUI
import Observation

/// One step of the guided flow. `event` is the action being taught. Order in
/// `RemoteWizardStep.coreSteps` is the walkthrough order.
struct RemoteWizardStep: Identifiable, Equatable {
    let event: RemoteEvent
    let title: String
    let instruction: String
    var id: RemoteEvent { event }

    /// The `RemoteEvent` a captured key should be bound to for this step.
    /// For most steps this is the step's own `event`. For the SCROLL steps we
    /// bind the pressed KEY to the one-line-step events (`.lineUp` /
    /// `.lineDown`) so a discrete d-pad press nudges one line — matching the
    /// default d-pad behaviour — rather than to the pointer-only `.scrollUp` /
    /// `.scrollDown` vocabulary, which has no bindable key anyway (those come
    /// straight off pointer travel). `internal` so it's unit-testable.
    var boundEvent: RemoteEvent {
        switch event {
        case .scrollUp:   return .lineUp
        case .scrollDown: return .lineDown
        default:          return event
        }
    }

    /// The core actions the wizard teaches, in order. Deliberately a small,
    /// opinionated set — play/pause, the two scroll directions, and record —
    /// so a fresh remote is usable in four presses. Everything else stays in
    /// the advanced table below the wizard entry.
    static let coreSteps: [RemoteWizardStep] = [
        RemoteWizardStep(
            event: .playPause,
            title: "Play / Pause",
            instruction: "Press the button you want to START and STOP scrolling."
        ),
        RemoteWizardStep(
            event: .scrollUp,
            title: "Scroll Up",
            instruction: "Press the button you want to nudge the script UP (back toward earlier lines)."
        ),
        RemoteWizardStep(
            event: .scrollDown,
            title: "Scroll Down",
            instruction: "Press the button you want to nudge the script DOWN (forward)."
        ),
        RemoteWizardStep(
            event: .recordToggle,
            title: "Record",
            instruction: "Press the button you want to START and STOP recording. (Works while the camera is on.)"
        )
    ]
}

/// The step-progression + capture + binding engine behind the wizard, with no
/// SwiftUI dependency so the capture→bind flow is unit-testable directly.
///
/// Flow per step: sources call `capture(_:source:)` (or `capturePointerScroll`)
/// as the user presses buttons — the LATEST press wins, so a wrong button is
/// fixed by just pressing again. `commitAndAdvance()` writes the captured key
/// to the store (via `RemoteWizardStep.boundEvent`) and moves on; `skip()`
/// advances without touching the binding; `redo()` clears the current capture
/// to listen again. `isFinished` flips true past the last step so the view
/// dismisses.
@Observable
@MainActor
final class RemoteWizardModel {
    /// The SHARED store — writes go straight in, same as the advanced list.
    let bindings: RemoteBindingStore
    let steps: [RemoteWizardStep]

    private(set) var stepIndex: Int = 0
    /// Latest captured key for the CURRENT step (nil until a press / after redo
    /// / after advancing). What `commitAndAdvance()` binds.
    private(set) var capturedKey: RemoteKey?
    /// Source label of the captured input for the live "detected" readout.
    private(set) var capturedSource: String?
    /// Set when the current step's press was pointer-scroll travel (BLE-M5
    /// D-pad axes) which has NO bindable key — the UI tells the user it
    /// already scrolls rather than offering to bind it.
    private(set) var capturedPointerScroll: Bool = false
    /// True once the flow has advanced past the last step — the view dismisses.
    private(set) var isFinished: Bool = false

    init(bindings: RemoteBindingStore, steps: [RemoteWizardStep] = RemoteWizardStep.coreSteps) {
        self.bindings = bindings
        self.steps = steps
    }

    /// The step currently being taught. Safe to read while `!isFinished`.
    var currentStep: RemoteWizardStep { steps[min(stepIndex, steps.count - 1)] }
    var isLastStep: Bool { stepIndex == steps.count - 1 }
    /// 0…1 across the flow, for the top progress bar.
    var progressFraction: Double {
        guard !steps.isEmpty else { return 0 }
        return Double(stepIndex) / Double(steps.count)
    }

    /// The physical key currently bound to THIS step's action, if any — shown
    /// as the "currently bound" row so the user sees what they're replacing.
    var currentBoundKey: RemoteKey? {
        let target = currentStep.boundEvent
        return bindings.allBindings.first { $0.event == target }?.key
    }

    /// Record a resolved key for the current step. Overwrites any earlier press
    /// (and clears a prior pointer-scroll note) so pressing again just fixes a
    /// mistake. Captures BEFORE the binding gate, so an unmapped button lands.
    func capture(_ key: RemoteKey, source: String) {
        capturedPointerScroll = false
        capturedKey = key
        capturedSource = source
    }

    /// Note a pointer-scroll press (BLE-M5 D-pad axes). No bindable key exists
    /// — the pointer source hardwires travel to scroll — so we only inform.
    /// A real key press afterwards still wins (guarded on `capturedKey == nil`).
    func capturePointerScroll() {
        guard capturedKey == nil else { return }
        capturedPointerScroll = true
    }

    /// Clear the current step's capture so the user can press a different
    /// button ("redo").
    func redo() {
        capturedKey = nil
        capturedSource = nil
        capturedPointerScroll = false
    }

    /// Bind the captured key (if any) to this step's action, then advance.
    /// No-op binding when nothing was captured — behaves like `skip()` then.
    func commitAndAdvance() {
        if let key = capturedKey {
            bindings.setBinding(currentStep.boundEvent, for: key)
        }
        advance()
    }

    /// Advance WITHOUT changing the binding (skip).
    func skip() {
        advance()
    }

    private func advance() {
        capturedKey = nil
        capturedSource = nil
        capturedPointerScroll = false
        if isLastStep {
            isFinished = true
        } else {
            stepIndex += 1
        }
    }
}

struct RemoteWizardView: View {
    /// The SHARED store — the wizard writes bindings straight into it, same as
    /// the advanced list. No parallel state.
    @Bindable var bindings: RemoteBindingStore
    let monitor: KeyboardConnectionMonitor
    /// Dismiss the wizard sheet.
    @Binding var isPresented: Bool
    /// Whether the volume opt-in is active. Read LIVE from `@AppStorage` (not a
    /// constructor snapshot) so `startCapture()` always wires the volume source
    /// against the CURRENT value when the sheet appears — the shutter is the
    /// founder's primary button, so a stale `false` here would silently make it
    /// unlearnable. (2.5.9: source wired ONLY when this is true.)
    @AppStorage(PrefKey.useVolumeButtons.rawValue) private var useVolumeButtons: Bool = false

    @State private var model: RemoteWizardModel

    // Capture plumbing — a capture-only bus + sources, torn down on disappear.
    @State private var captureBus = RemoteEventBus()
    @State private var keyboardSource: KeyboardEventSource?
    @State private var gcKeyboardSource: GameControllerKeyboardSource?
    @State private var mouseSource: GCMouseSource?
    @State private var mediaSource: MediaCommandSource?
    @State private var volumeSource: VolumeEventSource?
    /// Set if the volume source fails to activate its audio session — surfaced
    /// in the diagnostic caption instead of being swallowed, so a shutter that
    /// never registers is EXPLAINED (round-2: the wizard used to swallow this).
    @State private var volumeStatus: String?
    /// Flipped true on the first raw GCMouse movement, so the caption can
    /// confirm the D-pad is reaching the app as a pointer even when a nudge is
    /// below the scroll-step threshold (which would otherwise show nothing).
    @State private var sawPointerMovement: Bool = false
    @FocusState private var captureFocused: Bool

    init(
        bindings: RemoteBindingStore,
        monitor: KeyboardConnectionMonitor,
        isPresented: Binding<Bool>
    ) {
        self.bindings = bindings
        self.monitor = monitor
        self._isPresented = isPresented
        self._model = State(initialValue: RemoteWizardModel(bindings: bindings))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progressBar
                Form {
                    Section {
                        stepHeader
                    }

                    Section {
                        detectionReadout
                    } header: {
                        Text("press your button")
                    } footer: {
                        captureDiagnostics
                    }

                    Section {
                        currentBindingRow
                    } header: {
                        Text("currently bound")
                    } footer: {
                        Text("your captured button replaces this when you tap next / finish.")
                            .font(.system(size: 12))
                    }
                }
            }
            .navigationTitle("learn your remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("cancel") { isPresented = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(model.isLastStep ? "done" : "skip") {
                        model.skip()
                        finishIfNeeded()
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        // The button is disabled unless a key is captured, so
                        // this always commits a real binding — give a tap.
                        model.commitAndAdvance()
                        Haptics.tap()
                        finishIfNeeded()
                    } label: {
                        Text(model.isLastStep ? "finish" : "next")
                            .font(.system(size: 16, weight: .bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.capturedKey == nil)
                }
            }
            // Focus glue so the SwiftUI .onKeyPress fallback fires while the GC
            // sources also listen focus-free. Both feed the same capture sink.
            .focusable()
            .focused($captureFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in
                keyboardSource?.handle(press) ?? .ignored
            }
            .task { await startCapture() }
            .task {
                // Drain the capture bus purely to latch the honest connection
                // chip — these events do NOT drive any prompter.
                for await _ in captureBus.events {
                    monitor.noteRemoteEvent()
                }
            }
            .onChange(of: model.isFinished) { _, finished in
                if finished { isPresented = false }
            }
            .onDisappear { stopCapture() }
        }
    }

    private func finishIfNeeded() {
        if model.isFinished { isPresented = false }
    }

    // MARK: - Subviews

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Theme.ghost.opacity(0.4))
                Rectangle()
                    .fill(Theme.green)
                    .frame(width: geo.size.width * model.progressFraction)
                    .animation(.easeInOut(duration: 0.2), value: model.stepIndex)
            }
        }
        .frame(height: 4)
    }

    private var stepHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("step \(model.stepIndex + 1) of \(model.steps.count)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.dim)
            Text(model.currentStep.title)
                .font(.system(size: 24, weight: .bold))
            Text(model.currentStep.instruction)
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var detectionReadout: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.capturedKey != nil || model.capturedPointerScroll ? Theme.green : Theme.ghost)
                .frame(width: 10, height: 10)
            if let key = model.capturedKey {
                VStack(alignment: .leading, spacing: 2) {
                    Text("detected: \(key.displayName)")
                        .font(.system(size: 16, weight: .semibold))
                    if let src = model.capturedSource {
                        Text(src.uppercased())
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.muted)
                    }
                }
            } else if model.capturedPointerScroll {
                Text("that's a pointer d-pad — it already scrolls the prompter. no binding needed.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            } else {
                Text("waiting for a press…")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
            Spacer()
            if model.capturedKey != nil {
                Button {
                    model.redo()
                } label: {
                    Label("redo", systemImage: "arrow.counterclockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    /// Under-the-readout diagnostic so a wizard that shows "waiting for a
    /// press…" forever is EXPLAINED rather than mysterious: it tells the
    /// founder whether iOS sees a pointer / keyboard at all, and whether the
    /// volume path (the BLE-M5 shutter) is being listened to. If a press does
    /// nothing, this line says why.
    @ViewBuilder
    private var captureDiagnostics: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("we can see — pointer: \(monitor.isMouseConnected ? "yes" : "no")  ·  keyboard: \(monitor.isKeyboardConnected ? "yes" : "no")  ·  pointer moving: \(sawPointerMovement ? "yes" : "no")")
            if let volumeStatus {
                Text("volume error — \(volumeStatus)")
            } else {
                Text(useVolumeButtons
                     ? "volume listening: on (a shutter / volume button will register)"
                     : "volume listening: off — cancel and turn on 'use volume buttons' first to learn a shutter / volume-button remote (e.g. the BLE-M5 shutter).")
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Theme.dim)
    }

    @ViewBuilder
    private var currentBindingRow: some View {
        HStack {
            Text(model.currentStep.boundEvent.displayName)
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Text(model.currentBoundKey?.displayName ?? "unbound")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(model.currentBoundKey == nil ? Theme.dim : Theme.muted)
        }
    }

    // MARK: - Capture wiring

    @MainActor
    private func startCapture() async {
        // Fresh GameController snapshot so the diagnostic caption reflects a
        // remote paired before the wizard opened.
        monitor.refreshConnectedDevices()

        // Each source records the resolved key into the model BEFORE the
        // binding gate, so a still-unmapped button is captured. Latest press
        // wins; the user commits or redoes explicitly.
        keyboardSource = KeyboardEventSource(
            bus: captureBus,
            store: bindings,
            onCapture: { [model] key in model.capture(key, source: "keyboard") }
        )

        let gc = GameControllerKeyboardSource(
            bus: captureBus,
            store: bindings,
            onCapture: { [model] key in model.capture(key, source: "keyboard") }
        )
        gcKeyboardSource = gc
        gc.start()

        let mouse = GCMouseSource(
            bus: captureBus,
            store: bindings,
            onCapture: { [model] key in model.capture(key, source: "mouse") },
            onScrollCapture: { [model] _ in model.capturePointerScroll() },
            onRawPointer: { _, _ in sawPointerMovement = true }
        )
        mouseSource = mouse
        mouse.start()

        let media = MediaCommandSource(
            bus: captureBus,
            store: bindings,
            onCapture: { [model] key in model.capture(key, source: "media") }
        )
        mediaSource = media
        media.start()

        // Volume capture only when the user has the opt-in on (App Store
        // 2.5.9). The shutter on the founder's BLE-M5 is a volume button, so
        // this is the ONLY way to learn it — but never enabled implicitly.
        // The `onCapture` hook is load-bearing: without it a shutter press
        // would publish to the bus but never reach `model.capture`, leaving
        // the step's "next / finish" button disabled — the founder couldn't
        // bind their primary (working) button.
        if useVolumeButtons {
            let volume = VolumeEventSource(
                bus: captureBus,
                store: bindings,
                onCapture: { [model] key in model.capture(key, source: "volume") },
                onActivationFailure: { message in volumeStatus = message }
            )
            volumeSource = volume
            volume.start()
        }

        captureFocused = true
    }

    private func stopCapture() {
        gcKeyboardSource?.stop()
        mouseSource?.stop()
        mediaSource?.stop()
        volumeSource?.stop()
        captureFocused = false
    }
}

//
//  TeleprompterView.swift
//  OpenPrompter
//
//  The prompter itself. One scrolling block of text, optional mirror flip
//  on horizontal and/or vertical axes, auto-scroll driven by TimelineView,
//  dimmable chrome. Controls live OUTSIDE the mirrored ZStack so they're
//  always readable regardless of flip state.
//

import SwiftUI

struct TeleprompterView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var vm: PrompterViewModel
    @State private var changeWatcher: Task<Void, Never>? = nil

    // Bluetooth-remote sources. Keyboard handler lives on the view so we can
    // hand it directly to `.onKeyPress`; media + volume are owned by the VM
    // because their lifecycle ties to the prompter's appearance, not the
    // current focus state. They're constructed in `.task` once we have the
    // shared binding store from AppState.
    @State private var keyboardSource: KeyboardEventSource?
    @State private var mediaSource: MediaCommandSource?
    @State private var volumeSource: VolumeEventSource?
    /// SwiftUI focus binding for the keyboard event source. Must be true
    /// while the prompter is the active scene or `.onKeyPress` will not
    /// fire. Defaults to true on appear and resets to false on disappear.
    @FocusState private var prompterFocused: Bool

    // Live-read prefs that gate which sources are active. UserDefaults-backed
    // so a Settings change applies on the next prompter open without a
    // manual rebuild of the view model.
    @AppStorage(PrefKey.remoteEnabled.rawValue) private var remoteEnabled: Bool = true
    @AppStorage(PrefKey.useVolumeButtons.rawValue) private var useVolumeButtons: Bool = false

    // Camera Style + PiP (V2 Feature 1). Read live so the camera section
    // applies to the open prompter view. The store on AppState owns the
    // session — these flags drive overlay composition.
    @AppStorage(PrefKey.cameraStyle.rawValue) private var cameraStyleRaw: String = "off"
    @AppStorage(PrefKey.coachMarkCameraStyleShown.rawValue) private var coachMarkShown: Bool = false
    @AppStorage(PrefKey.labsCameraStyle.rawValue) private var labsCameraStyleEnabled: Bool = false
    @State private var showCameraDeniedBanner: Bool = false
    @State private var showCameraIntroBanner: Bool = false

    // Prompter font pref is read live via @AppStorage so picker changes in
    // Settings propagate instantly — even to an already-open prompter view.
    // Stored VM state would go stale because Settings is presented modally
    // from the library, not the prompter.
    @AppStorage(PrefKey.prompterFont.rawValue) private var prompterFontRaw: String = PrompterFont.default.rawValue
    private var prompterFont: PrompterFont {
        PrompterFont(rawValue: prompterFontRaw) ?? .default
    }

    /// Resolved enum from the @AppStorage raw string. Falls back to `.off`
    /// for an unknown value (downgrade safety).
    private var cameraStyle: CameraStyle {
        CameraStyle(rawValue: cameraStyleRaw) ?? .off
    }

    init(file: ScriptFile) {
        _vm = State(initialValue: PrompterViewModel(file: file))
    }

    var body: some View {
        ZStack {
            // Backdrop. In `.behind` mode the camera fills the screen and
            // we DON'T paint Theme.bg over it. In `.pip` and `.off` we paint
            // Prompter Black behind the text (the PiP tile sits as an
            // overlay; the prompter still reads against pure black).
            if cameraStyle != .behind {
                Theme.bg.ignoresSafeArea()
            }

            // `.behind` mode: full-frame camera preview. Mirror axes (V2
            // Feature 6) compose against the preview layer — same source
            // of truth as the text scale.
            if cameraStyle == .behind {
                CameraPreview(
                    session: appState.cameraStore.session,
                    gravity: .resizeAspectFill,
                    horizontalMirror: vm.mirroredHorizontal,
                    verticalMirror: vm.mirroredVertical
                )
                .ignoresSafeArea()
                // Scrim behind the reading line: WCAG 2.2 AA contrast over
                // live video. 0.55 is the spec default; raise to 0.7 at AX5
                // Dynamic Type sizes per V2 Design 01 §"`behind` — full-
                // frame camera, prompter overlay".
                Color(red: 10.0/255, green: 10.0/255, blue: 11.0/255)
                    .opacity(scrimOpacityForBehindMode)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // Scrolling text — full-bleed, measures its own viewport internally.
            // Mirror is applied as a pair of independent scale flips per
            // Roadmap V2 §6 ("Mirror mode — second axis"). The text layer is
            // the only thing that flips here; the top bar and controls live
            // outside this ZStack so they stay legible regardless of mirror
            // state.
            // The camera preview transform composes against the SAME two
            // booleans (V2 Feature 1) so the rig optics line up against a
            // single source of truth.
            scrollingText
                .scaleEffect(
                    x: vm.mirroredHorizontal ? -1 : 1,
                    y: vm.mirroredVertical ? -1 : 1
                )
                .animation(.easeInOut(duration: Theme.mirrorAnim), value: vm.mirroredHorizontal)
                .animation(.easeInOut(duration: Theme.mirrorAnim), value: vm.mirroredVertical)

            // Auto-scroll driver — invisible, just ticks the AutoScroller.
            TimelineView(.animation(minimumInterval: nil, paused: !vm.isPlaying)) { context in
                Color.clear.frame(width: 1, height: 1)
                    .onChange(of: context.date) { _, newDate in
                        guard vm.isPlaying else { return }
                        let delta = vm.scroller.advance(now: newDate, speed: vm.speed)
                        vm.scroller.apply(delta: delta, maxOffset: vm.maxScrollOffset)
                        if vm.scroller.didReachEnd {
                            vm.isPlaying = false
                        }
                    }
            }

            // Loading / error — centered
            if vm.isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Theme.fg)
            } else if let error = vm.loadError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                    Text("Couldn't load this file.")
                        .font(.system(size: Theme.sizeButton, weight: .bold))
                    Text(error)
                        .font(.system(size: Theme.sizePill, weight: .regular))
                        .foregroundStyle(Theme.dim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .foregroundStyle(Theme.fg)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // PiP tile floats above the text but below the chrome. Disabled
        // for `.behind` (preview is the backdrop) and `.off` (no session).
        .overlay {
            if cameraStyle == .pip {
                PipTile(
                    store: appState.cameraStore,
                    horizontalMirror: vm.mirroredHorizontal,
                    verticalMirror: vm.mirroredVertical
                )
                .opacity(vm.focus ? 0.0 : 1.0)
                .animation(.easeInOut(duration: Theme.focusAnim), value: vm.focus)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                PrompterTopBarView(vm: vm)
                if showCameraDeniedBanner {
                    cameraDeniedBanner
                }
                if showCameraIntroBanner {
                    cameraIntroBanner
                }
            }
            .padding(.top, 4)
            .opacity(vm.focus ? 0.0 : 1.0)
            .allowsHitTesting(!vm.focus)
            .animation(.easeInOut(duration: Theme.focusAnim), value: vm.focus)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 6) {
                // Camera Style chip lives just above the existing controls,
                // visible whenever Labs is on or the user has picked a non-
                // off style. Same gating logic as the Settings section.
                if showCameraChip {
                    HStack(spacing: 8) {
                        Spacer()
                        CameraStyleChip(store: appState.cameraStore)
                        Spacer()
                    }
                }
                PrompterControlsView(vm: vm)
            }
            .padding(.bottom, 6)
            .opacity(vm.focus ? 0.0 : 1.0)
            .allowsHitTesting(!vm.focus)
            .animation(.easeInOut(duration: Theme.focusAnim), value: vm.focus)
        }
        // Tally-light: 4pt red border that pulses while recording. Drawn
        // last so nothing in the chrome can occlude it (V2 Design 01
        // §"Tally-light border indicator"). Reduce-Motion is honored
        // inside the overlay.
        .overlay {
            TallyLightOverlay(isActive: appState.recordingState.isRecording)
        }
        .overlay(alignment: .bottomTrailing) {
            Button(action: { vm.toggleFocus() }) {
                Image(systemName: "eye")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Theme.fg.opacity(0.9))
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Theme.controlBorder, lineWidth: 1))
            }
            .padding(.trailing, 16)
            .padding(.bottom, 16)
            .opacity(vm.focus ? 1.0 : 0.0)
            .allowsHitTesting(vm.focus)
            .animation(.easeInOut(duration: Theme.focusAnim), value: vm.focus)
        }
        .ignoresSafeArea(.keyboard)
        .contentShape(Rectangle())
        .onTapGesture { vm.togglePlay() }
        // Keyboard focus + .onKeyPress wiring (Feature 7). Without
        // .focusable() + .focused(), SwiftUI never delivers key events.
        // We mount these unconditionally so a user who opts back in mid-
        // session gets keys without re-entering the prompter; the source
        // returns .ignored when remoteEnabled is false.
        .focusable()
        .focused($prompterFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            guard remoteEnabled, let src = keyboardSource else { return .ignored }
            return src.handle(press)
        }
        .task { await vm.load() }
        .task(id: useVolumeButtons) {
            // Toggle the volume source whenever the opt-in changes. The
            // task identity restarts this when the @AppStorage value flips.
            // Volume capture is OFF by default — see VolumeEventSource.swift
            // for the App Store guideline 2.5.9 trade-off.
            if remoteEnabled, useVolumeButtons {
                if volumeSource == nil {
                    volumeSource = VolumeEventSource(
                        bus: vm.remoteBus,
                        store: appState.remoteBindings
                    )
                }
                volumeSource?.start()
            } else {
                volumeSource?.stop()
            }
        }
        .task {
            // Construct event sources once and start the always-on ones.
            // The keyboard source has no lifecycle of its own (it's driven
            // by .onKeyPress); media commands attach until prompter exits.
            keyboardSource = KeyboardEventSource(
                bus: vm.remoteBus,
                store: appState.remoteBindings
            )
            let media = MediaCommandSource(
                bus: vm.remoteBus,
                store: appState.remoteBindings
            )
            mediaSource = media
            if remoteEnabled { media.start() }

            // Take focus so .onKeyPress fires. Set after sources exist so
            // the first key press doesn't race the instantiation.
            prompterFocused = true
        }
        .task {
            // Drain remote events into the view model. Lives for the
            // duration of this view; the bus is per-VM and ends with it.
            for await event in vm.remoteBus.events {
                vm.handleRemoteEvent(event)
            }
        }
        .task {
            // Listen for file changes while this script is open.
            for await url in appState.watcher.changed {
                if url == vm.file.url {
                    vm.reloadAvailable = true
                }
            }
        }
        .onChange(of: remoteEnabled) { _, newValue in
            // Settings flipped the master toggle while the prompter is on
            // screen. Start / stop the long-lived sources so the change
            // applies immediately — without this, the user has to leave
            // and re-enter the prompter for the toggle to take effect.
            // The volume source has its own `.task(id:)` upstream which
            // also re-evaluates `remoteEnabled` indirectly via this branch
            // when the user has the volume opt-in on.
            if newValue {
                mediaSource?.start()
                if useVolumeButtons { volumeSource?.start() }
            } else {
                mediaSource?.stop()
                volumeSource?.stop()
            }
        }
        // Camera lifecycle (V2 Feature 1). Resume on appear if mode != off
        // AND permission is granted; suspend on disappear so the privacy
        // LED extinguishes promptly. The store's `setStyle` already started
        // the session if the user just flipped via the chip — `resume()` is
        // idempotent so calling it here is safe.
        .task {
            await appState.cameraStore.resume()
        }
        .onChange(of: appState.cameraStore.pendingPermissionDeniedBanner) { _, isPending in
            // Drive the "camera access is off" banner directly off the
            // store flag, not off `cameraStyleRaw`. The denial path snaps
            // the chosen style back to `.off`, which is identical to the
            // prior value when the user picked .pip from .off — so an
            // `onChange(of: cameraStyleRaw)` would never fire and the
            // banner would be silently swallowed. This observation runs
            // exactly when the store flips the flag, regardless of style.
            guard isPending else { return }
            if appState.cameraStore.consumePermissionDenialBanner() {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showCameraDeniedBanner = true
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Stop the session on background to extinguish the privacy LED;
            // resume on foreground if the mode demands it. iOS will already
            // pause AVCaptureSession on its own, but explicit stop releases
            // the camera holds and clears the LED on real hardware.
            switch newPhase {
            case .active:
                Task { await appState.cameraStore.resume() }
            case .background, .inactive:
                Task { await appState.cameraStore.suspend() }
            @unknown default:
                break
            }
        }
        .task {
            // First-launch coach-mark banner. Surfaces "Try the new camera
            // modes" the first time the prompter opens after the v2 update.
            // Auto-dismisses on first style change or after 8s.
            if !coachMarkShown && cameraStyle == .off {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showCameraIntroBanner = true
                }
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                withAnimation(.easeInOut(duration: 0.18)) {
                    showCameraIntroBanner = false
                }
                coachMarkShown = true
            }
        }
        .onDisappear {
            mediaSource?.stop()
            volumeSource?.stop()
            prompterFocused = false
            Task { await appState.cameraStore.suspend() }
        }
        .statusBarHidden()
        // The teleprompter reading view is ALWAYS dark, regardless of the
        // user's appearance preference. A bright screen behind teleprompter
        // glass creates glare and washes the reflection. The Settings
        // appearance pref only controls the library/settings/picker chrome.
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var scrollingText: some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .center, spacing: vm.fontSize * 0.45) {
                    ForEach(Array(vm.parsed.blocks.enumerated()), id: \.offset) { _, block in
                        blockView(for: block)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                // Top padding lets the first line start roughly mid-viewport (eye-line).
                // Bottom padding lets the last line scroll up past the middle.
                .padding(.top, geo.size.height * 0.5)
                .padding(.bottom, geo.size.height * 0.8)
                .background(
                    GeometryReader { inner in
                        Color.clear
                            .onAppear {
                                vm.contentHeight = inner.size.height
                                vm.viewportHeight = geo.size.height
                            }
                            .onChange(of: inner.size.height) { _, new in
                                vm.contentHeight = new
                            }
                    }
                )
                .offset(y: -vm.scroller.offset)
            }
            .scrollDisabled(vm.isPlaying)
            .onAppear { vm.viewportHeight = geo.size.height }
            .onChange(of: geo.size.height) { _, new in
                vm.viewportHeight = new
            }
        }
    }

    @ViewBuilder
    private func blockView(for block: ScriptBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            // Headings stay in the brand monospace so they still feel
            // like script section markers, regardless of which body font
            // the user has picked.
            Text(text)
                .font(.system(size: headingSize(level: level), weight: .heavy, design: .monospaced))
                .tracking(-vm.fontSize * 0.02)
                .foregroundStyle(Theme.fg)
                .multilineTextAlignment(.center)
                .lineSpacing(vm.fontSize * 0.2)
                .frame(maxWidth: .infinity, alignment: .center)

        case .paragraph(let text):
            Text(text)
                .font(prompterFont.swiftUIFont(size: vm.fontSize, weight: .regular))
                .tracking(bodyTracking)
                .foregroundStyle(Theme.fg)
                .multilineTextAlignment(.center)
                .lineSpacing(vm.fontSize * 0.45)
                .frame(maxWidth: .infinity, alignment: .center)

        case .bullet(let text):
            listRow(marker: "▸", text: text)

        case .numbered(let index, let text):
            listRow(marker: "\(index).", text: text)
        }
    }

    @ViewBuilder
    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: vm.fontSize * 0.35) {
            // Bullet markers stay monospace so numbers / arrows line up
            // regardless of the body font. It's a structural element,
            // not part of the reading line.
            Text(marker)
                .font(.system(size: vm.fontSize, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.green)
            Text(text)
                .font(prompterFont.swiftUIFont(size: vm.fontSize, weight: .regular))
                .tracking(bodyTracking)
                .foregroundStyle(Theme.fg)
                .multilineTextAlignment(.leading)
                .lineSpacing(vm.fontSize * 0.4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, vm.fontSize * 0.25)
    }

    /// Negative tracking works for monospace (tightens the loose default
    /// spacing). Proportional body fonts already sit at their designed
    /// spacing, so zero out tracking for anything other than Brand Mono.
    private var bodyTracking: CGFloat {
        switch prompterFont {
        case .brandMono: return -vm.fontSize * 0.01
        default:         return 0
        }
    }

    private func headingSize(level: Int) -> CGFloat {
        let multiplier: CGFloat
        switch level {
        case 1: multiplier = 1.45
        case 2: multiplier = 1.25
        default: multiplier = 1.1
        }
        return min(vm.fontSize * multiplier, 180)
    }

    // MARK: - Camera helpers (V2 Feature 1)

    /// Show the camera chip in the bottom-bar area whenever Labs is on or
    /// the user has already picked a non-`.off` style. Mirrors the gating
    /// logic in `SettingsView` so the two surfaces line up. Reads via
    /// `@AppStorage` so a Settings flip propagates without re-mounting.
    /// `Prefs.register()` seeds the right `#if DEBUG` default.
    private var showCameraChip: Bool {
        labsCameraStyleEnabled || cameraStyle != .off
    }

    /// Scrim opacity for `.behind` mode. 0.55 by default (per V2 Design 01
    /// §"`behind` — full-frame camera, prompter overlay"); raised to 0.7 at
    /// AX5 Dynamic Type sizes for WCAG 2.2 AA contrast over live video.
    private var scrimOpacityForBehindMode: Double {
        switch dynamicTypeSize {
        case .accessibility5, .accessibility4: return 0.7
        default: return 0.55
        }
    }

    @ViewBuilder
    private var cameraDeniedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "video.slash")
                .font(.system(size: 13, weight: .bold))
            Text("camera access is off — open Settings to enable")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .tracking(0.5)
            Spacer()
            Button {
                #if canImport(UIKit)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                #endif
                withAnimation(.easeInOut(duration: 0.18)) {
                    showCameraDeniedBanner = false
                }
            } label: {
                Text("OPEN")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.surface, in: Capsule())
                    .foregroundStyle(Theme.fg)
                    .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
            }
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showCameraDeniedBanner = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.amber.opacity(0.6), lineWidth: 1)
        )
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private var cameraIntroBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "camera")
                .font(.system(size: 13, weight: .bold))
            Text("try the new camera modes — tap the camera chip below")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .tracking(0.5)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showCameraIntroBanner = false
                }
                coachMarkShown = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.green.opacity(0.6), lineWidth: 1)
        )
        .padding(.horizontal, 10)
    }
}

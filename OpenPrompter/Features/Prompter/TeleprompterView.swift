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
    /// Editor sheet visibility — bound to the new bottom-row Edit chip.
    /// Lived in PrompterTopBarView before the dogfood-pass-2 control move.
    @State private var showEditor: Bool = false
    /// Tick clock for the relative-time formatter on the sync chip. Lived
    /// in PrompterTopBarView before the move; refreshed once per minute
    /// while the prompter is on screen.
    @State private var nowForSync: Date = .now
    /// SwiftUI focus binding for the keyboard event source. Must be true
    /// while the prompter is the active scene or `.onKeyPress` will not
    /// fire. Defaults to true on appear and resets to false on disappear.
    @FocusState private var prompterFocused: Bool

    /// Wall-clock timestamp at which the current play span began. Set
    /// when `vm.isPlaying` flips true; consumed when it flips false. The
    /// elapsed delta feeds `ReviewPromptCounter.recordPlaySession(...)`
    /// for Feature 8's engagement signal. `nil` when paused.
    @State private var playSessionStartedAt: Date? = nil

    /// READ line — fraction of viewport height where the matched
    /// (just-spoken) word is meant to land. Default 0.05 puts the
    /// matched word right at the top of the screen for selfie-cam
    /// eye contact. Drives the scroll target via `target =
    /// matchedContentY - readY`.
    /// (Storage key kept as `boxTopFraction` so 2.0.x users with
    /// existing values don't silently lose them on upgrade.)
    @AppStorage("pref.voice.boxTopFraction")
    private var voiceReadFraction: Double = 0.05

    /// FEATHER line — fraction of viewport height where the velocity
    /// controller transitions from "snappy catch-up" to "smooth
    /// glide". The DISTANCE between READ and FEATHER (`feather =
    /// voiceFeatherFraction - voiceReadFraction`) drives the
    /// controller's gain + velocityAlpha. Tighter spacing → snappier
    /// recognition follow; wider → smoother momentum that feels like
    /// a continuous scroll instead of word-by-word lurches.
    /// Pre-2.0.2 this value was unused in scroll math; the founder's
    /// intuition that "spread the band for smoother glide" finally
    /// has a wiring after this rename + refactor.
    /// (Storage key kept as `boxBottomFraction` for upgrade safety.)
    @AppStorage("pref.voice.boxBottomFraction")
    private var voiceFeatherFraction: Double = 0.18

    /// Mirror of `PipTile.hidden` published via `PipHiddenPreferenceKey`.
    /// Cosmetic only — `PipTile` now owns its own `CameraPreview` so the
    /// chevron-hidden state doesn't gate any camera mount up here. The
    /// flag is still surfaced for any future "dim peer chrome when the
    /// tile is hidden" affordance.
    @State private var pipHidden: Bool = false

    /// True when the user tapped the PiP tile to expand it to full-screen
    /// preview ("how do I look?" check). The full-screen overlay shows the
    /// camera feed filling the screen with a minimize button to return to
    /// PiP. Replaces the old "behind" mode with a more intuitive iOS-PiP-
    /// style expand/collapse interaction.
    @State private var cameraPromoted: Bool = false

    /// Captured `vm.scroller.offset` at the moment a manual drag begins.
    /// The DragGesture's `value.translation` is relative to gesture start,
    /// so we apply the cumulative translation against this baseline and
    /// commit via `vm.scroller.seek(...)`. Reset to nil on drag end. Lives
    /// here (not on the view model) because it's a gesture-recognizer
    /// transient — no need to outlive the gesture.
    @State private var manualScrollBaseline: CGFloat? = nil

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

    // Recording (V2 Features 2 + 4). Labs gates visibility of the chip;
    // when the user has the chip on screen we mount the hardware-capture
    // bridge and listen for save / failure cues from the session.
    @AppStorage(PrefKey.labsRecording.rawValue) private var labsRecording: Bool = false
    @State private var recordingSavedToast: RecordingState.SavedToast? = nil
    @State private var icloudCopyFailureMessage: String? = nil
    @State private var recoveryURL: URL? = nil

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
            // Backdrop — Prompter Black behind the scrolling text.
            Theme.bg.ignoresSafeArea()

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

            // Auto-scroll + voice-lerp driver — invisible, just ticks
            // the AutoScroller every frame. Active when EITHER play is
            // running OR voice tracking has a pending lerp target.
            TimelineView(.animation(minimumInterval: nil, paused: scrollTickerPaused)) { context in
                Color.clear.frame(width: 1, height: 1)
                    .onChange(of: context.date) { _, newDate in
                        handleScrollTick(now: newDate)
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
        // Read PipTile's hidden state so any future "dim peer chrome when
        // the tile is tucked away" affordance has a hook. The camera
        // preview itself lives inside `PipTile` now (dogfood-pass-11
        // architecture), so the preference is no longer load-bearing for
        // mounting — purely informational.
        .onPreferenceChange(PipHiddenPreferenceKey.self) { newHidden in
            pipHidden = newHidden
        }
        // PiP tile — pre-warmed whenever the camera is on (.pip or .behind)
        // so the .behind → .pip switch is instant (the preview layer inside
        // PipTile is already connected to the session and receiving frames).
        // Opacity 0 + allowsHitTesting(false) keeps it invisible and inert
        // in behind mode. Goes away entirely in .off (session stopped).
        .overlay {
            if cameraStyle == .pip {
                PipTile(
                    store: appState.cameraStore,
                    horizontalMirror: vm.mirroredHorizontal,
                    verticalMirror: vm.mirroredVertical,
                    chromeVisible: !vm.focus,
                    promoted: $cameraPromoted,
                    onPromote: { cameraPromoted = true }
                )
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
                if let toast = recordingSavedToast {
                    recordingSavedToastBanner(toast)
                }
                if let reason = icloudCopyFailureMessage {
                    iCloudCopyFailureBanner(reason)
                }
                if let url = recoveryURL {
                    RecoveryBanner(
                        url: url,
                        onRecover: { handleRecoveryRecover(url: url) },
                        onDiscard: { handleRecoveryDiscard(url: url) }
                    )
                }
            }
            // No extra top padding — sit flush with the safe-area inset so
            // the reading line falls under the front-camera lens (the user
            // wanted the script raised toward eye-level).
            .opacity(vm.focus || cameraPromoted ? 0.0 : 1.0)
            .allowsHitTesting(!vm.focus && !cameraPromoted)
            .animation(.easeInOut(duration: Theme.focusAnim), value: vm.focus)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 6) {
                // Bottom chip strip — centralized control row per the
                // dogfood-pass-2 reshuffle. From left to right:
                //   [Edit] [Sync/Edited] [Camera Style] [REC] [Mirror status]
                //
                // Camera Style and REC are gated by their respective Labs/
                // permission flags; the others always render.
                bottomChipStrip
                PrompterControlsView(
                    vm: vm,
                    voiceTracker: appState.voiceTracker,
                    onPlayTap: handlePlayTap,
                    onVoiceTap: handleVoiceTap
                )
            }
            .padding(.bottom, 6)
            .opacity(vm.focus || cameraPromoted ? 0.0 : 1.0)
            .allowsHitTesting(!vm.focus)
            .animation(.easeInOut(duration: Theme.focusAnim), value: vm.focus)
        }
        // Tally-light: 4pt red border that pulses while recording. Drawn
        // last so nothing in the chrome can occlude it (V2 Design 01
        // §"Tally-light border indicator"). Reduce-Motion is honored
        // inside the overlay. The recording-indicator preference
        // (V2 Design 02 review note 6) gates the in-app border so the
        // user can pick island-only / both / tally-only.
        .overlay {
            TallyLightOverlay(
                isActive: appState.recordingState.isRecording && tallyLightAllowedByPref
            )
        }
        // (Removed in dogfood pass 8: the in-app Dynamic-Island-style pill
        // overlay was redundant against the existing screen-edge tally
        // light AND the elapsed-time counter on the bottom-bar REC chip.
        // ActivityKit's real Live Activity still surfaces on the actual
        // Dynamic Island when the app is backgrounded; in-foreground we
        // rely on the tally light + bottom chip.)
        // Countdown 3-2-1 overlay. Renders only during the countdown phase;
        // tap-anywhere on the dim cancels back to idle.
        .overlay {
            CountdownOverlay(
                state: appState.recordingState,
                onCancel: {
                    Task { await appState.recordingSession.tapCancelDuringCountdown() }
                }
            )
        }
        // Hardware capture buttons (V2 Design 02 §"Hardware capture
        // buttons"). The interaction is enabled whenever the recording chip
        // is visible — volume / Camera Control / Action button start the
        // countdown / cancel / stop, mirroring the chip taps. Disabled
        // gracefully on iOS <17.2; the camera chip-only path stays clean.
        .background(
            HardwareCaptureBridge(
                isEnabled: showRecordingChip,
                onPrimary: { handleRecordingChipTap() },
                onSecondary: { handleRecordingChipTap() }
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        )
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
        .onTapGesture { if !cameraPromoted { vm.togglePlay() } }
        // Manual scrub-back / scrub-forward via finger drag while paused.
        // The ScrollView underneath has `scrollDisabled(true)` always, so
        // this DragGesture is the only path that actually moves the
        // `vm.scroller.offset` when the user wants to revisit earlier
        // sections after a long take.
        //
        // Why not let the ScrollView scroll natively? The prompter content
        // is positioned by `.offset(y: -vm.scroller.offset)` — a view
        // shift, not a real scroll position. The ScrollView's own scroll
        // position is independent of (and ignorant of) the offset shift.
        // After a long auto-scroll, the offset is large, content is shifted
        // way up visually, but the ScrollView still thinks the top of the
        // natural content is at top — there's nothing for it to scroll
        // back through. This DragGesture bridges the gap by treating the
        // whole prompter as a virtual scroll surface that maps drag
        // translation directly to the offset.
        //
        // `minimumDistance: 10` keeps a quick tap (toggle play) from
        // accidentally triggering a 1-pixel scroll. Drag input is ignored
        // while playing — auto-scroll owns the offset there.
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    guard !vm.isPlaying else { return }
                    if manualScrollBaseline == nil {
                        manualScrollBaseline = vm.scroller.offset
                        // First tick of a fresh drag — if voice tracking
                        // is active, suspend its momentum so the velocity
                        // controller doesn't fight the user's manual
                        // scroll (the "scrolls back forward when I try to
                        // re-read a section" symptom). The next genuine
                        // match will re-aim from the new scroll position.
                        if appState.voiceTracker.isActive {
                            vm.voiceTargetOffset = nil
                            vm.scroller.resetVoiceVelocity()
                        }
                    }
                    let baseline = manualScrollBaseline ?? 0
                    // Translation.height: + when finger moves down, − when up.
                    // Drag-up should pull "later" text into the reading line
                    // (offset increases), so invert the translation sign.
                    let target = baseline - value.translation.height
                    vm.scroller.seek(to: target, maxOffset: vm.maxScrollOffset)
                }
                .onEnded { value in
                    let baseline = manualScrollBaseline
                    manualScrollBaseline = nil
                    guard !vm.isPlaying, let baseline else { return }

                    // Scroll inertia. iOS already computes
                    // `predictedEndTranslation` from the gesture's release
                    // velocity — slow drag → roughly equal to the actual
                    // translation (snap-to-where-finger-lifted), fast flick
                    // → significant overshoot for the post-release glide
                    // that makes scrolling feel native.
                    //
                    // Animate vm.scroller.offset from where it sat at
                    // release to the predicted-end target via easeOut.
                    // The clamp inside scroller.seek() handles flicks past
                    // the head/tail of the script — they decelerate into
                    // the boundary rather than overshooting it.
                    //
                    // Duration scales mildly with the inertial distance so
                    // a tiny overshoot doesn't get a 0.7 s tail and a big
                    // flick doesn't snap. 0.18-0.65 s window, capped to
                    // keep the prompter from feeling laggy.
                    let inertialTarget = baseline - value.predictedEndTranslation.height
                    let clampedTarget = min(max(0, inertialTarget), vm.maxScrollOffset)
                    let inertialDistance = abs(clampedTarget - vm.scroller.offset)
                    let duration = min(0.65, max(0.18, Double(inertialDistance) / 1800.0))
                    withAnimation(.easeOut(duration: duration)) {
                        vm.scroller.seek(to: inertialTarget, maxOffset: vm.maxScrollOffset)
                    }
                }
        )
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
        // 2.0.6: bootstrap the camera session on prompter open so a
        // fresh launch with `cameraStyle = .pip` shows a live preview
        // immediately. The OpenPrompterApp-level bootstrap can race
        // the user opening a script (permissions take time, the user
        // may navigate fast). `bootstrapSessionForLaunchStyle` is
        // idempotent — guards on `!isSessionRunning` so a repeat call
        // when the session is already up is a no-op.
        .task { await appState.cameraStore.bootstrapSessionForLaunchStyle() }
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
        .onChange(of: vm.isPlaying) { _, nowPlaying in
            // Feature 8 engagement tracking. Stamp the start of each play
            // span; on flip to paused, count it (sessions ≥ 30 s only,
            // shorter ones are usually the user fiddling with controls
            // rather than reading). Pause-resume cycles each get their
            // own session — that's by design, since each is a discrete
            // "I sat down to read for a while" event.
            if nowPlaying {
                playSessionStartedAt = .now
            } else if let start = playSessionStartedAt {
                let elapsed = Date.now.timeIntervalSince(start)
                appState.reviewPromptCounter.recordPlaySession(durationSeconds: elapsed)
                playSessionStartedAt = nil
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
                // Feature 8: ask for an App Store review on a fresh
                // foreground if the user has crossed the engagement
                // threshold. The controller's predicate is the gate; this
                // call is a no-op when thresholds aren't met or we've
                // already prompted in this app version.
                ReviewPromptController.requestReviewIfAppropriate(
                    counter: appState.reviewPromptCounter
                )
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
        // Recording lifecycle: tell the session which script is loaded
        // (drives the Live Activity title and the iCloud-next-to-script
        // copy destination) and start the audio-route monitor so the
        // Settings status row reflects what iOS is actually picking up.
        .task {
            appState.recordingSession.setCurrentScript(
                url: vm.file.url,
                displayName: vm.file.displayName
            )
            appState.audioRouteMonitor.start()
        }
        // Mirror the saved toast / iCloud failure / recovery cues from
        // RecordingState into local @State so SwiftUI animates them in
        // and out via the banner overlay.
        .onChange(of: appState.recordingState.pendingSavedToast) { _, _ in
            if let toast = appState.recordingState.consumeSavedToast() {
                withAnimation(.easeInOut(duration: 0.2)) {
                    recordingSavedToast = toast
                }
                Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        recordingSavedToast = nil
                    }
                }
            }
        }
        .onChange(of: appState.recordingState.pendingICloudCopyFailure) { _, _ in
            if let reason = appState.recordingState.consumeICloudCopyFailure() {
                withAnimation(.easeInOut(duration: 0.2)) {
                    icloudCopyFailureMessage = reason
                }
            }
        }
        .onChange(of: appState.recordingState.pendingRecoveryBanner) { _, _ in
            if let url = appState.recordingState.consumeRecoveryBanner() {
                withAnimation(.easeInOut(duration: 0.2)) {
                    recoveryURL = url
                }
            }
        }
        .task {
            // Drain a recovery banner queued before the prompter opened
            // (the AppState init-time scan posts to recordingState before
            // anything subscribes).
            if let url = appState.recordingState.consumeRecoveryBanner() {
                withAnimation(.easeInOut(duration: 0.2)) {
                    recoveryURL = url
                }
            }
        }
        .onDisappear {
            mediaSource?.stop()
            volumeSource?.stop()
            prompterFocused = false
            Task { await appState.cameraStore.suspend() }
            // Tear down a live recording on disappear so the file gets
            // saved if the user navigates away mid-take.
            Task { await appState.recordingSession.teardown() }
            // Voice tracking is opt-in and per-script — stopping on
            // disappear avoids a stale recognizer task lingering when
            // the user navigates back to the library.
            appState.voiceTracker.stop()
            appState.audioRouteMonitor.stop()
        }
        .statusBarHidden()
        // The teleprompter reading view is ALWAYS dark, regardless of the
        // user's appearance preference. A bright screen behind teleprompter
        // glass creates glare and washes the reflection. The Settings
        // appearance pref only controls the library/settings/picker chrome.
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        // Voice-tracking surface — debug HUD overlay + reading-line
        // indicator + cursor-advance scroll. Wrapped as a single
        // ViewModifier so the type-checker doesn't have to consider
        // these additions as part of TeleprompterView.body's chain.
        .modifier(
            VoiceTrackingChrome(
                tracker: appState.voiceTracker,
                readFraction: $voiceReadFraction,
                featherFraction: $voiceFeatherFraction,
                onCursorChange: handleVoiceCursorChange,
                layoutKey: VoiceTrackingChrome.LayoutKey(
                    fontSize: vm.fontSize,
                    contentHeight: vm.contentHeight,
                    viewportHeight: vm.viewportHeight
                ),
                // Focus mode: chrome hides, READ/FEATHER lines dim to
                // 20% so the user can still see + drag them without
                // exiting focus.
                focusDimmed: vm.focus
            )
        )
    }

    @ViewBuilder
    private var scrollingText: some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .center, spacing: vm.fontSize * 0.45) {
                    ForEach(Array(vm.parsed.blocks.enumerated()), id: \.offset) { idx, block in
                        blockView(for: block)
                            // 2.0.6: publish each rendered block's
                            // frame inside the `scriptContent` named
                            // coordinate space so voice tracking can
                            // resolve matched-token pixel positions
                            // from real geometry. PreferenceKey reduce
                            // is dictionary-merge so multiple blocks
                            // composing keeps each frame intact.
                            .background(
                                GeometryReader { blockGeo in
                                    Color.clear.preference(
                                        key: BlockFramesPreferenceKey.self,
                                        value: [
                                            idx: BlockFrame(
                                                minY: blockGeo.frame(in: .named("scriptContent")).minY,
                                                height: blockGeo.size.height
                                            )
                                        ]
                                    )
                                }
                            )
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                // Top padding lets the first line start roughly mid-viewport (eye-line).
                // Bottom padding lets the last line scroll up past the middle.
                .padding(.top, geo.size.height * 0.5)
                .padding(.bottom, geo.size.height * 0.8)
                .coordinateSpace(name: "scriptContent")
                .onPreferenceChange(BlockFramesPreferenceKey.self) { frames in
                    vm.blockFrames = frames
                }
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
            // ScrollView's own scroll is permanently disabled. The visible
            // scroll position is driven entirely by `.offset(y: -vm.scroller.offset)`
            // above, and the user's finger gestures are captured by the
            // DragGesture on the prompter root (which calls
            // `vm.scroller.seek(...)`). Letting the ScrollView scroll
            // natively would race the offset shift and leave the user
            // unable to scrub back to earlier sections after long auto-scroll.
            .scrollDisabled(true)
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

    // MARK: - Recording helpers (V2 Features 2 + 4)

    /// Show the recording chip when Labs is on AND we have a live camera
    /// session — the user can't record without a preview. Mirrors the
    /// roadmap's "recording requires a live camera" gate.
    private var showRecordingChip: Bool {
        labsRecording && cameraStyle != .off
    }

    /// Tally light visibility — driven by `RecordingIndicatorPref`. The
    /// preference is read live so a Settings flip during a take updates
    /// the overlay immediately.
    private var tallyLightAllowedByPref: Bool {
        let raw = Prefs.recordingIndicator
        let pref = RecordingIndicatorPref(rawValue: raw) ?? .both
        return pref.showsTallyLight
    }

    /// Single dispatch point for chip taps + hardware capture button
    /// presses. Phase determines what the next action is — start countdown
    /// from idle, cancel from countdown, stop from recording.
    private func handleRecordingChipTap() {
        switch appState.recordingState.phase {
        case .idle:
            Task { await appState.recordingSession.tapREC() }
        case .countdown:
            Task { await appState.recordingSession.tapCancelDuringCountdown() }
        case .recording:
            Task { await appState.recordingSession.tapStop() }
        case .finalizing, .saving:
            // No-op — the chip is disabled in these phases anyway.
            break
        case .error:
            // Tap during error clears the error and goes back to idle.
            appState.recordingState.dismissError()
        }
    }

    private func handleRecoveryRecover(url: URL) {
        Task {
            let ok = await RecoveryAction.recoverToPhotos(url: url)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    recoveryURL = nil
                    if ok {
                        recordingSavedToast = RecordingState.SavedToast(
                            photosWritten: true,
                            scriptFolderWritten: false
                        )
                    }
                }
                if recordingSavedToast != nil {
                    Task {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        withAnimation(.easeInOut(duration: 0.2)) {
                            recordingSavedToast = nil
                        }
                    }
                }
            }
        }
    }

    private func handleRecoveryDiscard(url: URL) {
        RecordingFileStore.removeRecording(at: url)
        withAnimation(.easeInOut(duration: 0.2)) {
            recoveryURL = nil
        }
    }

    @ViewBuilder
    private func recordingSavedToastBanner(_ toast: RecordingState.SavedToast) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.green)
            Text(toast.displayText)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .tracking(0.5)
            Spacer()
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

    @ViewBuilder
    private func iCloudCopyFailureBanner(_ reason: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 13, weight: .bold))
            VStack(alignment: .leading, spacing: 2) {
                Text("saved to photos")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                Text("couldn't save next to script — \(reason.lowercased())")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    icloudCopyFailureMessage = nil
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

    // MARK: - Bottom chip strip (dogfood pass 2)

    /// Relative-time formatter for the sync chip. Static so we don't
    /// rebuild the formatter on every render.
    private static let syncRelativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// Fallback short-date formatter for files modified more than a week
    /// ago, where relative phrasing ("2w AGO") is less scannable than a
    /// fixed "APR 21" date.
    private static let syncShortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    /// Centralized chip strip — Edit + Sync + (Camera Style) + (REC) +
    /// Mirror status, in that order. Camera Style and REC are conditional
    /// on Labs/style state; Edit/Sync/Mirror always render so the user has
    /// a stable visual frame for the strip.
    @ViewBuilder
    private var bottomChipStrip: some View {
        HStack(spacing: 8) {
            editChip
            syncChip
            Spacer(minLength: 4)
            if showCameraChip {
                CameraStyleChip(store: appState.cameraStore)
            }
            if showRecordingChip {
                RecordingChip(state: appState.recordingState) {
                    handleRecordingChipTap()
                }
            }
            Spacer(minLength: 4)
            mirrorStatusPill
        }
        .padding(.horizontal, 10)
        .sheet(isPresented: $showEditor) {
            ScriptEditorSheet(
                file: vm.file,
                cachedSource: vm.rawText.isEmpty ? nil : vm.rawText,
                initialOffset: vm.sourceOffsetForCurrentView(),
                onSaved: {
                    Task { await vm.reload() }
                }
            )
        }
        // Refresh the "x min ago" label once a minute while visible.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                nowForSync = .now
            }
        }
    }

    /// Edit chip — pencil glyph. Tap pauses any in-flight playback and
    /// presents the script editor sheet.
    @ViewBuilder
    private var editChip: some View {
        Button(action: {
            // Pause first if the prompter is mid-take so the script doesn't
            // keep scrolling behind the editor sheet. We don't auto-resume
            // on dismiss — the user can reach for play intentionally when
            // they're ready.
            if vm.isPlaying { vm.togglePlay() }
            showEditor = true
        }) {
            Image(systemName: "pencil")
                .font(.system(size: 13, weight: .bold))
                .frame(width: 36, height: 32)
                .background(Theme.surface, in: Capsule())
                .foregroundStyle(Theme.fg)
                .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Edit script")
    }

    /// Sync/edited chip — shows the on-disk last-edited time, or a RELOAD
    /// affordance when the watcher sees a newer mtime than what's loaded.
    @ViewBuilder
    private var syncChip: some View {
        if vm.reloadAvailable {
            Button(action: { Task { await vm.reload() } }) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.amber)
                        .frame(width: 6, height: 6)
                        .shadow(color: Theme.amber.opacity(0.85), radius: 3)
                    Text("RELOAD")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Theme.amber)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(minHeight: Theme.hitMin)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().stroke(Theme.amber.opacity(0.6), lineWidth: 1))
            }
        } else if let mtime = vm.fileMTime {
            // After the dogfood-pass-2 strip move there's less width to
            // burn — drop the "EDITED · " prefix and let the green dot +
            // relative-time text carry the meaning ("3M AGO"). Tooltip /
            // VoiceOver still reads the full phrasing.
            LiveChip(status: .live, label: syncLabelText(for: mtime))
        } else if vm.isLoading {
            LiveChip(status: .syncing, label: "LOADING…", pulse: true)
        } else {
            LiveChip(status: .live, label: "READY")
        }
    }

    /// Compound mirror status pill — H, V, H+V, OFF. Tap toggles the
    /// horizontal axis (matches the existing PrompterControlsView behavior
    /// so the user has a single tap-target for the most common case).
    @ViewBuilder
    private var mirrorStatusPill: some View {
        Button(action: { vm.toggleMirror() }) {
            if vm.mirroredHorizontal || vm.mirroredVertical {
                Pill(text: mirrorPillText, alert: true)
            } else {
                Pill(text: "MIRROR OFF")
            }
        }
        .accessibilityLabel("Toggle horizontal mirror")
        .accessibilityValue(Text(mirrorPillText))
    }

    private var mirrorPillText: String {
        switch (vm.mirroredHorizontal, vm.mirroredVertical) {
        case (true, true): return "MIRROR H+V"
        case (true, false): return "MIRROR H"
        case (false, true): return "MIRROR V"
        default: return "MIRROR OFF"
        }
    }

    /// Human-readable "time since edit" for the sync chip.
    /// - < 15s: "NOW"
    /// - < 7 days: RelativeDateTimeFormatter abbreviated ("30S AGO", "12M AGO", "3H AGO", "2D AGO")
    /// - >= 7 days: short date ("APR 21") — relative phrasing stops being scannable past a week
    private func syncLabelText(for mtime: Date) -> String {
        let delta = nowForSync.timeIntervalSince(mtime)
        if delta < 15 { return "NOW" }
        let week: TimeInterval = 7 * 24 * 60 * 60
        if delta >= week {
            return Self.syncShortDateFormatter.string(from: mtime).uppercased()
        }
        return Self.syncRelativeFormatter
            .localizedString(for: mtime, relativeTo: nowForSync)
            .uppercased()
    }

    // MARK: - Voice tracking orchestration (V2 Feature 5)

    /// Tap handler for the PLAY half of the bottom row. Stops voice
    /// tracking first (mutually exclusive) then runs the existing play
    /// toggle.
    private func handlePlayTap() {
        if appState.voiceTracker.isActive {
            appState.voiceTracker.stop()
        }
        vm.togglePlay()
    }

    /// Tap handler for the VOICE half. Toggles voice tracking on/off
    /// with the permission flow on first use. Pauses auto-scroll if it
    /// was running.
    private func handleVoiceTap() {
        let tracker = appState.voiceTracker
        if tracker.isActive {
            tracker.stop()
            // Clear voice scroll state so the next activation
            // doesn't inherit a stale target / velocity.
            vm.voiceTargetOffset = nil
            vm.lastVoiceTickAt = nil
            vm.scroller.resetVoiceVelocity()
            return
        }
        // Activating — pause auto-scroll if it's running.
        if vm.isPlaying { vm.togglePlay() }

        // Load the script's body text. Tokenization is fast (it
        // walks the string once) so it's fine to do on tap.
        let body = vm.parsed.bodyText
        guard !body.isEmpty else {
            appState.userFacingError = "Open a script first."
            return
        }
        // 2.0.6: load via the block-aware path so the tracker can
        // expose `cursorBlockLocation` for accurate matched-word
        // positioning. The view captures rendered block frames via
        // `BlockFramesPreferenceKey`; tracker provides
        // (blockIndex, withinBlockFraction); together that's the
        // exact pixel position even with mixed font sizes /
        // headings, replacing the linear-by-char approximation that
        // landed words below READ pre-2.0.6.
        let blockEntries = vm.parsed.blocks.enumerated().map { (index, block) in
            (blockIndex: index, text: block.text)
        }
        tracker.loadScript(blocks: blockEntries)
        // Reset scroll state so this activation starts clean —
        // without this, a leftover `voiceTargetOffset` from a prior
        // session would drag the scroll back to that old position
        // when the velocity ticker resumes (the "scrolls to top"
        // symptom on re-activation).
        vm.voiceTargetOffset = nil
        vm.lastVoiceTickAt = nil
        vm.scroller.resetVoiceVelocity()

        switch tracker.authorization {
        case .authorized:
            startVoiceOrSurfaceFailure()
        case .notDetermined:
            tracker.requestAuthorization { status in
                if status == .authorized {
                    startVoiceOrSurfaceFailure()
                } else if let reason = tracker.ineligibilityReason {
                    appState.userFacingError = reason
                }
            }
        case .denied, .restricted:
            appState.userFacingError = tracker.ineligibilityReason
                ?? "Voice tracking is not available."
        }
    }

    private func startVoiceOrSurfaceFailure() {
        let tracker = appState.voiceTracker
        let session = appState.recordingSession
        // Snapshot visible-range so the very first match is constrained
        // to what's on screen, not the whole script.
        let topPad = vm.viewportHeight * 0.5
        let bottomPad = vm.viewportHeight * 0.8
        let bodyHeight = max(0, vm.contentHeight - topPad - bottomPad)
        tracker.updateVisibleTokenRange(
            scrollOffset: vm.scroller.offset,
            viewportHeight: vm.viewportHeight,
            contentHeight: vm.contentHeight,
            bodyTopPad: topPad,
            bodyHeight: bodyHeight
        )
        Task {
            // 2.0.4: voice tracking owns its own AVAudioEngine input
            // tap; this call is now a no-op when camera is off (its
            // own guard skips when there's no camera audio output to
            // attach). Kept so a SIMULTANEOUS recording flow gets the
            // shared mic path through the recorder's writer.
            await session.ensureAudioCaptureRunning()
            if !tracker.start() {
                appState.userFacingError =
                    "Couldn't start voice tracking. Try again in a moment."
            }
        }
    }

    /// Translate a cursor advance into a target scroll offset.
    ///
    /// Model: TOP edge is where matched (just-spoken) words land.
    /// As the cursor advances, target shifts so the new matched word
    /// lands at the top edge — meaning the previous matched word has
    /// already drifted UP and is on its way to scrolling off-screen,
    /// and the next-to-be-spoken word sits BELOW the matched word
    /// (typically near the BOTTOM edge if the band height matches
    /// roughly one word height). This is the "top = words leaving,
    /// bottom = eyeballs" semantic the user requested.
    ///
    /// Critically, this also means scroll responds to the VERY FIRST
    /// matched word (target = matchedContentY - topY). The previous
    /// "matched at bottom" model clamped target to 0 until the user
    /// had read past `bottomY` of content — feeling like "scroll
    /// doesn't move until I'm at the bottom of the screen".
    fileprivate func handleVoiceCursorChange() {
        guard appState.voiceTracker.isActive,
              vm.contentHeight > 0,
              vm.viewportHeight > 0 else { return }
        // Don't fight the user's finger. If a manual drag is in
        // progress, ignore match-driven target updates until the
        // drag ends — otherwise a match arriving mid-drag would
        // re-set the lerp target and the velocity controller would
        // pull scroll away from where the user is dragging.
        if manualScrollBaseline != nil { return }
        // Refresh the visible-range with current geometry FIRST. The
        // aligner uses it on the next match. Without this, a font-
        // size change would race the next match with stale geometry.
        let topPadHandle = vm.viewportHeight * 0.5
        let bottomPadHandle = vm.viewportHeight * 0.8
        let bodyHeightHandle = max(0, vm.contentHeight - topPadHandle - bottomPadHandle)
        appState.voiceTracker.updateVisibleTokenRange(
            scrollOffset: vm.scroller.offset,
            viewportHeight: vm.viewportHeight,
            contentHeight: vm.contentHeight,
            bodyTopPad: topPadHandle,
            bodyHeight: bodyHeightHandle
        )
        // 2.0.6: prefer the per-block frame path when available — it's
        // pixel-accurate. The captured `vm.blockFrames` give us each
        // rendered block's actual minY + height, and
        // `cursorBlockLocation` tells us which block + how far through
        // it the matched token sits. Multiplying within-block fraction
        // by the real block height (rather than estimating from char
        // count over total bodyHeight) eliminates the systematic
        // "matched word lands below READ" error on scripts with mixed
        // block sizes (headings + body).
        //
        // 2.0.7 baseline offset: SwiftUI Text frames start at the
        // ascender top, but the visual CENTER of a rendered line sits
        // about half a line-height below frame.minY. Pre-2.0.7, the
        // linear-within-block math placed matched-word position at
        // (block.minY + small fraction × height) — which on the first
        // line of a block predicts ~ascender top and visually lands
        // the actual letter form ~half-a-line BELOW where READ wants
        // it. User's "always 5% below READ" symptom was that exact
        // gap. Adding a fontSize×0.5 nudge centers the prediction on
        // the line's visual midpoint where the eye actually reads.
        let cursorContentY: CGFloat
        if let location = appState.voiceTracker.cursorBlockLocation,
           let frame = vm.blockFrames[location.blockIndex] {
            let baselineNudge = CGFloat(vm.fontSize) * 0.5
            cursorContentY = frame.minY + CGFloat(location.fraction) * frame.height + baselineNudge
        } else if let fraction = appState.voiceTracker.cursorScriptFraction {
            // Linear-by-char fallback for the legacy `loadScript(_:)`
            // path (tests, mostly) — accounts for top/bottom padding
            // but doesn't know about per-block heights.
            let topPad = vm.viewportHeight * 0.5
            let bottomPad = vm.viewportHeight * 0.8
            let bodyHeight = max(0, vm.contentHeight - topPad - bottomPad)
            cursorContentY = topPad + CGFloat(fraction) * bodyHeight
        } else {
            return
        }
        let readY = vm.viewportHeight * CGFloat(voiceReadFraction)
        // Always aim for matched word at the READ line.
        let target = cursorContentY - readY
        vm.voiceTargetOffset = max(0, target)
    }

    /// Per-frame ticker — handles BOTH play auto-scroll AND voice-
    /// tracking lerp-toward-target. Called from the TimelineView in
    /// `body`.
    private func handleScrollTick(now: Date) {
        if vm.isPlaying {
            let delta = vm.scroller.advance(now: now, speed: vm.speed)
            vm.scroller.apply(delta: delta, maxOffset: vm.maxScrollOffset)
            if vm.scroller.didReachEnd {
                vm.isPlaying = false
            }
        }
        if appState.voiceTracker.isActive {
            // Keep the aligner's visible-range constraint in sync with
            // current scroll geometry so a generic word can't match an
            // offscreen instance. Cheap O(n) walk over tokens.
            let topPadTick = vm.viewportHeight * 0.5
            let bottomPadTick = vm.viewportHeight * 0.8
            let bodyHeightTick = max(0, vm.contentHeight - topPadTick - bottomPadTick)
            appState.voiceTracker.updateVisibleTokenRange(
                scrollOffset: vm.scroller.offset,
                viewportHeight: vm.viewportHeight,
                contentHeight: vm.contentHeight,
                bodyTopPad: topPadTick,
                bodyHeight: bodyHeightTick
            )
            // Silence detection: if no successful match in the last
            // 1.5s, halt momentum so a paused user can scroll back to
            // re-read a section without the prompter pulling forward.
            // The next match will set a fresh target and the velocity
            // controller will ramp up smoothly from zero.
            let elapsedSinceMatch = Date().timeIntervalSince(appState.voiceTracker.lastMatchTime)
            if elapsedSinceMatch > 1.5 {
                if vm.voiceTargetOffset != nil {
                    vm.voiceTargetOffset = nil
                    vm.scroller.resetVoiceVelocity()
                }
            }
            if let target = vm.voiceTargetOffset {
                // Velocity-controlled scroll. P-controller drives a
                // velocity that aims at target; velocity itself is
                // low-pass filtered for smooth acceleration AND
                // deceleration.
                let dt: TimeInterval
                if let last = vm.lastVoiceTickAt {
                    dt = min(0.1, max(0, now.timeIntervalSince(last)))
                } else {
                    dt = 1.0 / 60.0
                }
                vm.lastVoiceTickAt = now
                // Scale max velocity with font size — at 32pt one
                // line is ~45pt tall; at 64pt it's ~90pt. Reading
                // pace (lines/sec) is roughly font-independent, so
                // velocity in pt/sec must scale with line height.
                // 6 × fontSize gives ~4 lines/sec ceiling at any
                // size. Floor of 150 to avoid pathologically slow
                // catch-up at tiny fonts.
                let maxVel: CGFloat = max(150, CGFloat(vm.fontSize) * 6)
                // FEATHER distance drives the controller's responsiveness:
                // tighter feather → snappier P-gain + higher velocityAlpha
                // (cursor stays in lockstep with recognized words);
                // wider feather → smoother momentum.
                let feather = CGFloat(voiceFeatherFraction - voiceReadFraction)
                vm.scroller.voiceTrackingTick(
                    target: target,
                    dt: dt,
                    maxOffset: vm.maxScrollOffset,
                    featherFraction: feather,
                    maxVelocity: maxVel
                )
            }
        } else {
            vm.lastVoiceTickAt = nil
            vm.scroller.resetVoiceVelocity()
        }
    }

    /// Pause the scroll ticker only when nothing wants it. Voice
    /// tracking ALWAYS keeps it alive (even pre-first-match) so the
    /// visible-range refresh in `handleScrollTick` keeps pace with
    /// scroll changes — otherwise the aligner's first match runs with
    /// a stale visible range from script-load time.
    private var scrollTickerPaused: Bool {
        if vm.isPlaying { return false }
        if appState.voiceTracker.isActive { return false }
        return true
    }
}

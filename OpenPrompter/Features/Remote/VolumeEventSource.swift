//
//  VolumeEventSource.swift
//  OpenPrompter
//
//  Observes `AVAudioSession.outputVolume` via KVO so volume-button presses
//  on cheap BLE clickers (AB Shutter 3, BLE-M5, and similar) can drive the
//  prompter.
//
//  ╭───────────────────────────── REVIEW RISK ─────────────────────────────╮
//  │ App Store Review Guideline 2.5.9 prohibits altering or disabling the  │
//  │ standard volume switches. Even a non-destructive observation pattern  │
//  │ (this file) has historically been flagged. Mitigation per the v2     │
//  │ research file: the source is OPT-IN ONLY, OFF BY DEFAULT, and the    │
//  │ Settings copy is explicit about the trade-off.                       │
//  │                                                                       │
//  │ Do NOT call `start()` automatically at launch. Do NOT call it at all │
//  │ unless the user has flipped the "Use volume buttons" toggle. The     │
//  │ owning code (`TeleprompterView`) reads `Prefs.useVolumeButtons` and  │
//  │ only starts this source when true.                                    │
//  ╰───────────────────────────────────────────────────────────────────────╯
//
//  ╭──────────────────── FIX 1a — press-oriented, coordinated ─────────────╮
//  │ Root causes fixed (Remote Input Audit §2a):                           │
//  │  • A1/A5 — the source no longer races `setCategory` on the shared     │
//  │    session. It CLAIMS `.ambientObservation` through                   │
//  │    `AudioSessionCoordinator` and subscribes to a re-arm callback so   │
//  │    it rebuilds its KVO whenever recording / voice release the         │
//  │    session, or an interruption / route-change fires.                  │
//  │  • A2/A3 — any KVO fire is treated as ONE debounced press (~120 ms),  │
//  │    NOT a signed delta. The BLE-M5 shutter alternates Volume Up↔Down   │
//  │    every press (BLE-M5 Capture.md), so direction is meaningless.      │
//  │  • A2 (rail) — `start()` nudges the cached baseline off the rail so a │
//  │    press at max system volume still registers as a change.            │
//  │  • A4 — the audio-session activation failure is surfaced via          │
//  │    `onActivationFailure` instead of being swallowed silently.         │
//  ╰────────────────────────────────────────────────────────────────────────╯
//

import AVFoundation
import Foundation
import os

#if DEBUG
/// `os_log` channel `[Remote-Capture]` for tracing whether the remote sources
/// actually run + emit in the "learn my remote" / capture contexts. The
/// founder's device is the only place the BLE-M5's real HID behaviour shows,
/// and Console filtered on this subsystem pins WHERE capture breaks (source
/// didn't start, KVO never fired, delta below threshold, onCapture reached).
/// Every remote source logs to the same subsystem/category so one filter
/// follows a full press end-to-end. Behind `#if DEBUG` so production is clean.
fileprivate let remoteCaptureLog = Logger(
    subsystem: "app.openprompter.remote",
    category: "Remote-Capture"
)
#endif

@MainActor
final class VolumeEventSource: NSObject, RemoteEventSource {
    private let bus: RemoteEventBus
    private let store: RemoteBindingStore
    private let coordinator: AudioSessionCoordinator

    /// Called on the main actor when audio-session activation fails so the
    /// owner can surface it (audit A4). Optional so tests / previews can omit.
    private let onActivationFailure: (String) -> Void

    /// Optional tap invoked with `.volumeUp` for every DEBOUNCED press, BEFORE
    /// the binding lookup — the "learn my remote" wizard / capture tool
    /// subscribes so a volume-button clicker (the founder's BLE-M5 shutter is
    /// a Consumer volume button, BLE-M5 Capture.md) actually shows up while
    /// learning. `nil` in the normal prompter path. `@MainActor` to match the
    /// caller (`handle` already hops to main) and every sink.
    private let onCapture: (@MainActor (RemoteKey) -> Void)?

    private var observed: Bool = false

    /// Cached previous `outputVolume`. Used only to detect that a change
    /// happened — NOT to infer direction (audit A2/A3: the BLE-M5 shutter
    /// alternates Up/Down every press, so a signed delta is meaningless).
    private var lastVolume: Float = 0

    /// We store our KVO observation as a token so `stop()` and re-arm can
    /// tear it down without the legacy `removeObserver(_:forKeyPath:)` dance.
    private var observation: NSKeyValueObservation?

    /// Token for the coordinator re-arm subscription, cleared on `stop()`.
    private var reArmToken: ObjectIdentifier?

    /// Leading-edge debounce window. Cheap clickers (and the KVO itself near
    /// the rails) can emit a press as two changes; ~120 ms collapses those to
    /// one while staying well under a human's repeat cadence.
    private let debounceInterval: TimeInterval = 0.12
    private var lastPressTime: Date = .distantPast

    init(
        bus: RemoteEventBus,
        store: RemoteBindingStore,
        coordinator: AudioSessionCoordinator = .shared,
        onCapture: (@MainActor (RemoteKey) -> Void)? = nil,
        onActivationFailure: @escaping (String) -> Void = { _ in }
    ) {
        self.bus = bus
        self.store = store
        self.coordinator = coordinator
        self.onCapture = onCapture
        self.onActivationFailure = onActivationFailure
        super.init()
    }

    func start() {
        guard !observed else {
            #if DEBUG
            remoteCaptureLog.info("volume.start ignored — already observing")
            #endif
            return
        }
        observed = true

        // Claim the shared session through the coordinator instead of racing
        // `setCategory` directly. Recording / voice outrank us and will win
        // the category; when they release, the coordinator re-establishes our
        // `.ambient` and re-arms us (see the re-arm handler below).
        if let error = coordinator.claim(.volumeObservation, configuration: .ambientObservation) {
            // Audit A4: surface instead of swallowing. The KVO would never
            // fire without an active session, so the user must know the
            // volume remote isn't listening.
            observed = false
            #if DEBUG
            remoteCaptureLog.error("volume.start CLAIM FAILED: \(error.localizedDescription, privacy: .public) — KVO NOT armed; the shutter won't be observed")
            #endif
            onActivationFailure(
                "Couldn't start volume-button control: \(error.localizedDescription)"
            )
            return
        }

        // Subscribe to re-arm so the KVO is rebuilt whenever the effective
        // session changes (recording/voice release, interruption, route
        // change). Without this the observer goes dead after the first
        // recording (audit A1/A5).
        reArmToken = coordinator.addReArmHandler({ [weak self] in
            self?.reArm()
        }, for: self)

        armObserver()

        #if DEBUG
        remoteCaptureLog.info("volume.start OK — claimed .volumeObservation, KVO armed, baseline=\(Double(self.lastVolume), privacy: .public), effectiveRole=\(String(describing: self.coordinator.effectiveRole), privacy: .public)")
        #endif
    }

    func stop() {
        guard observed else { return }
        observed = false
        observation?.invalidate()
        observation = nil
        if let token = reArmToken {
            coordinator.removeReArmHandler(token)
            reArmToken = nil
        }
        coordinator.release(.volumeObservation)
    }

    // MARK: - KVO (re)arming

    /// Build the `outputVolume` observation against the currently-active
    /// session and seed the baseline off the rail.
    private func armObserver() {
        observation?.invalidate()

        let session = AVAudioSession.sharedInstance()

        // Audit A2 (rail): seed the cached baseline nudged off whichever rail
        // we're sitting on so the FIRST press still reads as a change. iOS
        // won't let us move the hardware volume, but our own baseline is ours
        // to bias: pretend we're one notch below max (or above min) so a
        // Volume-Up press at 1.0 produces `new(1.0) != last(<1.0)`.
        lastVolume = Self.nudgedOffRail(session.outputVolume)

        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let self else { return }
            guard let new = change.newValue else { return }
            // KVO can deliver on a background queue. Hop to main so the
            // RemoteEventBus and downstream view-model subscribers stay on the
            // same actor as the rest of the prompter UI.
            Task { @MainActor in
                self.handle(newVolume: new)
            }
        }
    }

    /// Re-arm entry point invoked by the coordinator. Rebuilds the observer
    /// against the freshly-applied session. No-op if we've been stopped.
    private func reArm() {
        guard observed else { return }
        armObserver()
    }

    /// Bias a rail reading inward by one iOS volume notch (~1/16) so the
    /// cached baseline differs from a subsequent press at the same rail.
    /// `internal` so the rail behavior is unit-testable.
    static func nudgedOffRail(_ volume: Float) -> Float {
        let notch: Float = 1.0 / 16.0
        if volume >= 1.0 { return 1.0 - notch }
        if volume <= 0.0 { return notch }
        return volume
    }

    // MARK: - Press handling

    /// Treat ANY volume change as one debounced press (audit A2/A3). The
    /// direction is deliberately ignored — the BLE-M5 shutter alternates
    /// Up/Down every press, so a signed-delta read would misfire. We publish
    /// the `.volumeUp` binding as the canonical "shutter pressed" key; both
    /// `.volumeUp` and `.volumeDown` default to `.playPause` anyway, and the
    /// user can remap `.volumeUp` to whatever they want.
    ///
    /// `internal` with an injectable `now` so the debounce + change-detection
    /// logic is exercised in unit tests without a live `outputVolume` KVO.
    func handle(newVolume: Float, now: Date = Date()) {
        defer { lastVolume = newVolume }

        #if DEBUG
        // The load-bearing diagnostic: if this line NEVER logs on a shutter
        // press, the outputVolume KVO isn't delivering in this context (the
        // session isn't active / hot) — distinct from "delivered but dropped."
        remoteCaptureLog.info("volume.handle KVO fire new=\(Double(newVolume), privacy: .public) last=\(Double(self.lastVolume), privacy: .public)")
        #endif

        // No actual change → nothing to do. (KVO fires only on change, but a
        // re-arm reseed can deliver an initial identical value on some route
        // transitions; guard defensively.)
        guard newVolume != lastVolume else {
            #if DEBUG
            remoteCaptureLog.info("volume.handle dropped — no change from baseline")
            #endif
            return
        }

        // Leading-edge debounce: one press per window, ignore the trailing
        // echo some clickers emit.
        guard now.timeIntervalSince(lastPressTime) >= debounceInterval else {
            #if DEBUG
            remoteCaptureLog.info("volume.handle dropped — within debounce window")
            #endif
            return
        }
        lastPressTime = now

        #if DEBUG
        remoteCaptureLog.info("volume.handle PRESS → onCapture(.volumeUp) hook=\(self.onCapture != nil, privacy: .public)")
        #endif

        // Surface the debounced press to the capture tool BEFORE the binding
        // gate, so a volume-button clicker shows up in "learn my remote" even
        // if `.volumeUp` were unbound. Matches the pre-gate capture pattern of
        // every other source.
        onCapture?(.volumeUp)

        guard let event = store.event(for: .volumeUp) else { return }
        bus.publish(event)
    }

    /// Seed the baseline as `start()` would, nudged off the rail. `internal`
    /// so tests can drive `handle(newVolume:now:)` from a known baseline
    /// without constructing a live audio session.
    func seedBaseline(_ volume: Float) {
        lastVolume = Self.nudgedOffRail(volume)
    }

    /// The current cached baseline. Exposed for tests that need to feed the
    /// exact same value back through `handle` to prove the no-change guard.
    var currentBaselineForTesting: Float { lastVolume }
}

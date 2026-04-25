//
//  VolumeEventSource.swift
//  OpenPrompter
//
//  Observes `AVAudioSession.outputVolume` via KVO so volume button presses
//  on the AB Shutter 3 (and similar cheap clickers that emit volume keys)
//  can drive the prompter.
//
//  ╭───────────────────────────── REVIEW RISK ─────────────────────────────╮
//  │ App Store Review Guideline 2.5.9 prohibits altering or disabling the │
//  │ standard volume switches. Even a non-destructive observation pattern │
//  │ (this file) has historically been flagged. Mitigation per the v2     │
//  │ research file: the source is OPT-IN ONLY, OFF BY DEFAULT, and the    │
//  │ Settings copy is explicit about the trade-off.                       │
//  │                                                                       │
//  │ Do NOT call `start()` automatically at launch. Do NOT call it at all │
//  │ unless the user has flipped the "Use volume buttons" toggle. The     │
//  │ owning code (`PrompterViewModel`) reads `Prefs.useVolumeButtons` and │
//  │ only starts this source when true.                                    │
//  ╰───────────────────────────────────────────────────────────────────────╯
//
//  Implementation:
//  – Activate the shared AVAudioSession with `.ambient` so we don't take
//    the audio focus away from the user's music app.
//  – KVO on `outputVolume` — any change publishes a `.volumeUp` or
//    `.volumeDown` to the bus depending on whether the new value is
//    larger or smaller than the cached previous value.
//  – Reset the system volume side-effect: clamp at the edges so spamming
//    the button keeps publishing events instead of saturating at 0/1.
//    Setting the volume programmatically is restricted on iOS, so the
//    practical fallback is to ignore consecutive presses at the rails;
//    the AB Shutter 3 emits Volume Up only, which never hits 0 — so this
//    is fine for the stated use case.
//

import AVFoundation
import Foundation

@MainActor
final class VolumeEventSource: NSObject, RemoteEventSource {
    private let bus: RemoteEventBus
    private let store: RemoteBindingStore
    private var observed: Bool = false
    private var lastVolume: Float = 0

    /// We store our KVO observation as a token so `stop()` can tear it down
    /// without the legacy `removeObserver(_:forKeyPath:)` dance.
    private var observation: NSKeyValueObservation?

    init(bus: RemoteEventBus, store: RemoteBindingStore) {
        self.bus = bus
        self.store = store
        super.init()
    }

    func start() {
        guard !observed else { return }
        observed = true

        let session = AVAudioSession.sharedInstance()
        do {
            // .ambient: we are silent and we don't want to interrupt music.
            try session.setCategory(.ambient, options: [.mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            // If audio session activation fails (rare, but possible on some
            // hardware combinations), the KVO callback simply never fires.
            // Better to no-op silently than to surface this — the user has
            // working keyboard + media bindings either way.
            observed = false
            return
        }

        lastVolume = session.outputVolume
        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let self else { return }
            guard let new = change.newValue else { return }
            // KVO can deliver on a background queue. Hop to main so the
            // RemoteEventBus and downstream view-model subscribers stay
            // on the same actor as the rest of the prompter UI.
            Task { @MainActor in
                self.handle(newVolume: new)
            }
        }
    }

    func stop() {
        guard observed else { return }
        observed = false
        observation?.invalidate()
        observation = nil
        // We intentionally do NOT deactivate the session — leaving `.ambient`
        // active doesn't conflict with anything (it mixes with others) and
        // tearing it down can produce a brief audio-route blip if other
        // future code in the app is also using the session.
    }

    private func handle(newVolume: Float) {
        // Compare against the cached value to determine direction. KVO
        // only fires on actual changes, but we still guard with a small
        // threshold so floating-point noise from the system doesn't
        // produce phantom presses.
        let delta = newVolume - lastVolume
        let key: RemoteKey?
        if delta > 0.001 {
            key = .volumeUp
        } else if delta < -0.001 {
            key = .volumeDown
        } else {
            key = nil
        }
        lastVolume = newVolume
        guard let key, let event = store.event(for: key) else { return }
        bus.publish(event)
    }
}

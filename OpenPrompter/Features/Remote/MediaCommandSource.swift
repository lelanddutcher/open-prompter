//
//  MediaCommandSource.swift
//  OpenPrompter
//
//  Hooks `MPRemoteCommandCenter` so devices that emit "Consumer Control"
//  HID events (Satechi R2, Bluetooth headphones with media buttons, AirPods,
//  CarPlay buttons) can drive the prompter.
//
//  We register handlers for togglePlayPause / play / pause / next / prev,
//  consult the `RemoteBindingStore` for the user's mapping, and publish the
//  resulting `RemoteEvent` onto the shared bus.
//
//  We DO NOT activate `AVAudioSession` here — the prompter is silent, and
//  taking the audio session would steal focus from the user's music app and
//  cause iOS to show the lock-screen "now playing" UI for our app, which is
//  off-brand. `MPRemoteCommandCenter` happens to deliver these consumer-key
//  events even without an active media session in foreground apps.
//
//  Lifecycle: `start()` registers handlers, `stop()` clears them. The
//  prompter owns one of these and start/stops it as the prompter view
//  appears / disappears.
//

import Foundation
import MediaPlayer

@MainActor
final class MediaCommandSource: RemoteEventSource {
    private let bus: RemoteEventBus
    private let store: RemoteBindingStore
    private var registered: Bool = false

    /// Token-style references to the handlers so `stop()` can remove the
    /// exact handler we added, in case other code in the app later registers
    /// its own commands (recording, voice tracking) on the same singleton.
    private var togglePlayPauseHandler: Any?
    private var playHandler: Any?
    private var pauseHandler: Any?
    private var nextHandler: Any?
    private var prevHandler: Any?

    init(bus: RemoteEventBus, store: RemoteBindingStore) {
        self.bus = bus
        self.store = store
    }

    func start() {
        guard !registered else { return }
        registered = true
        let center = MPRemoteCommandCenter.shared()

        togglePlayPauseHandler = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.publish(for: .mediaPlayPause)
            return .success
        }
        playHandler = center.playCommand.addTarget { [weak self] _ in
            self?.publish(for: .mediaPlayPause)
            return .success
        }
        pauseHandler = center.pauseCommand.addTarget { [weak self] _ in
            self?.publish(for: .mediaPlayPause)
            return .success
        }
        nextHandler = center.nextTrackCommand.addTarget { [weak self] _ in
            self?.publish(for: .mediaNextTrack)
            return .success
        }
        prevHandler = center.previousTrackCommand.addTarget { [weak self] _ in
            self?.publish(for: .mediaPrevTrack)
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
    }

    func stop() {
        guard registered else { return }
        registered = false
        let center = MPRemoteCommandCenter.shared()
        if let h = togglePlayPauseHandler { center.togglePlayPauseCommand.removeTarget(h) }
        if let h = playHandler            { center.playCommand.removeTarget(h) }
        if let h = pauseHandler           { center.pauseCommand.removeTarget(h) }
        if let h = nextHandler            { center.nextTrackCommand.removeTarget(h) }
        if let h = prevHandler            { center.previousTrackCommand.removeTarget(h) }
        togglePlayPauseHandler = nil
        playHandler = nil
        pauseHandler = nil
        nextHandler = nil
        prevHandler = nil
    }

    private func publish(for key: RemoteKey) {
        guard let event = store.event(for: key) else { return }
        bus.publish(event)
    }
}

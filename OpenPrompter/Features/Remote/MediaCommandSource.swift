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
import os

#if DEBUG
/// Shared `[Remote-Capture]` channel (see VolumeEventSource for rationale).
fileprivate let remoteCaptureLog = Logger(
    subsystem: "app.openprompter.remote",
    category: "Remote-Capture"
)
#endif

@MainActor
final class MediaCommandSource: RemoteEventSource {
    private let bus: RemoteEventBus
    private let store: RemoteBindingStore

    /// Optional tap invoked with the resolved media `RemoteKey` for every
    /// incoming command, BEFORE the binding lookup — the Labs "learn my
    /// remote" capture tool subscribes so unmapped media buttons still
    /// surface. `nil` in the normal prompter path. `@MainActor` throughout.
    private let onCapture: (@MainActor (RemoteKey) -> Void)?

    private var registered: Bool = false

    /// Token-style references to the handlers so `stop()` can remove the
    /// exact handler we added, in case other code in the app later registers
    /// its own commands (recording, voice tracking) on the same singleton.
    private var togglePlayPauseHandler: Any?
    private var playHandler: Any?
    private var pauseHandler: Any?
    private var nextHandler: Any?
    private var prevHandler: Any?

    init(
        bus: RemoteEventBus,
        store: RemoteBindingStore,
        onCapture: (@MainActor (RemoteKey) -> Void)? = nil
    ) {
        self.bus = bus
        self.store = store
        self.onCapture = onCapture
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

        // Register a minimal Now-Playing entry. Without metadata, enabling
        // the commands above produces an empty "Now Playing" tile in
        // Control Center / lock screen, which (a) looks broken and (b) has
        // historically been flagged by App Store reviewers as media-session
        // abuse. A bare title satisfies the system's expectation that a
        // command-center registration corresponds to *something* playing.
        // Playback rate is 0 because the prompter is silent — we're using
        // the consumer-key delivery path, not actually serving audio.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Open Prompter",
            MPNowPlayingInfoPropertyPlaybackRate: 0.0
        ]
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

        // Clear our Now-Playing entry so other media apps reclaim the
        // lock-screen UI when our prompter exits the foreground.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func publish(for key: RemoteKey) {
        #if DEBUG
        remoteCaptureLog.info("media.publish key=\(key.id, privacy: .public) → onCapture hook=\(self.onCapture != nil, privacy: .public)")
        #endif
        onCapture?(key)
        guard let event = store.event(for: key) else { return }
        bus.publish(event)
    }
}

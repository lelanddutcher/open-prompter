//
//  AudioSessionCoordinator.swift
//  OpenPrompter
//
//  Single owner of the process-wide `AVAudioSession.sharedInstance()`.
//
//  ╭───────────────────────────── WHY THIS EXISTS ──────────────────────────╮
//  │ There is exactly ONE audio session per process and the last            │
//  │ `setCategory` wins. Three subsystems used to race it independently:    │
//  │   • RecordingSession → .playAndRecord / .videoRecording                │
//  │   • VoiceTracker     → .playAndRecord / .videoRecording                │
//  │   • VolumeEventSource → .ambient / .mixWithOthers                       │
//  │ VolumeEventSource armed its `outputVolume` KVO once against `.ambient`  │
//  │ and never reconciled when recording or voice flipped the category to   │
//  │ `.playAndRecord`. The result was the founder's "volume as play/pause   │
//  │ often doesn't fire" — a dead toggle with no re-arm. (Remote Input      │
//  │ Audit §2a, root cause A1/A5.)                                          │
//  │                                                                        │
//  │ This coordinator makes ownership explicit: each subsystem CLAIMS a     │
//  │ role and RELEASES it. The coordinator computes the winning category    │
//  │ by priority (recording ≥ voice > volume), applies it once, and — the   │
//  │ load-bearing part — notifies interested parties (the volume source)    │
//  │ whenever the effective session changes so they can re-arm their KVO.   │
//  │ It also re-applies on interruption / route-change / media-services     │
//  │ reset, the other cases that silently killed the volume observer.       │
//  ╰────────────────────────────────────────────────────────────────────────╯
//
//  This does NOT change the audio the recorder captures — recording and
//  voice still request the exact same `.playAndRecord` / `.videoRecording`
//  configuration they always did. It only serializes the requests and adds
//  a re-arm signal. Do NOT reach into `AVAudioSession.sharedInstance()`
//  directly from a subsystem again; route through here.
//

import AVFoundation
import Foundation

/// The three subsystems that contend for the shared audio session. Ordered
/// by priority: a recording claim outranks a voice claim, which outranks a
/// volume-observation claim. `rawValue` doubles as the priority (higher wins).
enum AudioSessionRole: Int, CaseIterable, Sendable {
    /// Passive `outputVolume` KVO for the volume-button remote. Lowest
    /// priority — it yields the category to any active capture consumer.
    case volumeObservation = 0
    /// Voice-tracked auto-scroll owns the mic via AVAudioEngine.
    case voiceTracking = 1
    /// Active video recording owns the mic + speaker route.
    case recording = 2
}

/// The concrete category/mode/options a role needs when it wins. Kept as a
/// small value type so the coordinator can compare and apply without knowing
/// which subsystem asked.
struct AudioSessionConfiguration: Equatable, Sendable {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions

    /// What recording + voice tracking both request: full-duplex capture in
    /// the video-recording mode with the usual Bluetooth / speaker routing.
    static let capture = AudioSessionConfiguration(
        category: .playAndRecord,
        mode: .videoRecording,
        options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
    )

    /// What the volume observer requests: silent, non-interrupting so the
    /// user's music keeps playing while we just watch `outputVolume`.
    static let ambientObservation = AudioSessionConfiguration(
        category: .ambient,
        mode: .default,
        options: [.mixWithOthers]
    )
}

/// Coordinates the single shared `AVAudioSession`. `@MainActor` because all
/// three callers already run on the main actor (RecordingSession, VoiceTracker,
/// VolumeEventSource) and audio-session mutation wants a single serialization
/// point anyway.
///
/// A process-wide singleton is deliberate: there is exactly one shared session,
/// so there must be exactly one coordinator. RecordingSession and VoiceTracker
/// live on `AppState`; VolumeEventSource is created per-prompter in
/// `TeleprompterView`. Threading a coordinator instance through all three
/// initializers would touch far more surface than fix 1a warrants, and the
/// singleton matches the one-shared-session reality.
@MainActor
final class AudioSessionCoordinator {

    static let shared = AudioSessionCoordinator()

    /// Callback invoked on the main actor whenever the effective session has
    /// changed underneath an observer — a claim/release that alters the
    /// winning category, an interruption ending, a route change, or a
    /// media-services reset. The volume source subscribes so it can re-arm
    /// its `outputVolume` KVO against the freshly-applied category. Multiple
    /// subscribers are supported (keyed by an opaque token).
    private var reArmHandlers: [ObjectIdentifier: () -> Void] = [:]

    /// Active claims by role → the configuration that role wants. Recording
    /// and voice both map to `.capture`; volume maps to `.ambientObservation`.
    private var claims: [AudioSessionRole: AudioSessionConfiguration] = [:]

    /// The configuration currently applied to the shared session, or nil if
    /// we've never applied one (nothing has claimed yet).
    private var appliedConfiguration: AudioSessionConfiguration?

    /// Guards `configureNotificationsIfNeeded` so we register the
    /// interruption / route-change observers exactly once.
    private var notificationsRegistered = false

    /// When true (unit tests), skip every real `AVAudioSession` call and
    /// notification registration. The claim bookkeeping and re-arm dispatch
    /// still run so tests can assert the coordination logic without device
    /// audio hardware.
    private let suppressSessionWork: Bool

    /// Designated initializer. The app uses `.shared`; tests construct their
    /// own instance with `suppressSessionWork: true`.
    init(suppressSessionWork: Bool = false) {
        self.suppressSessionWork = suppressSessionWork
    }

    // MARK: - Re-arm subscription

    /// Register a re-arm handler and return a token to unregister with. The
    /// handler fires on the main actor whenever the effective session may
    /// have changed under the subscriber's feet.
    @discardableResult
    func addReArmHandler(_ handler: @escaping () -> Void, for owner: AnyObject) -> ObjectIdentifier {
        let token = ObjectIdentifier(owner)
        reArmHandlers[token] = handler
        return token
    }

    /// Remove a previously-registered re-arm handler.
    func removeReArmHandler(_ token: ObjectIdentifier) {
        reArmHandlers.removeValue(forKey: token)
    }

    // MARK: - Claim / release

    /// Claim the shared session for `role`, applying `role`'s configuration if
    /// it now wins by priority. Idempotent per role. Recording and voice call
    /// this with `.capture`; the volume source calls it with
    /// `.ambientObservation`.
    ///
    /// Returns the error thrown by `setCategory` / `setActive`, or nil on
    /// success. Callers that used to swallow the failure (the volume source)
    /// can now surface it.
    @discardableResult
    func claim(_ role: AudioSessionRole, configuration: AudioSessionConfiguration) -> Error? {
        configureNotificationsIfNeeded()
        claims[role] = configuration
        return applyEffectiveConfiguration()
    }

    /// Release `role`'s claim. If a lower-priority claim remains (e.g. the
    /// volume observer is still active after recording stops), its category is
    /// re-established and subscribers are re-armed — this is the fix for "turn
    /// volume on → record → stop, nothing re-arms" (audit A5).
    func release(_ role: AudioSessionRole) {
        guard claims[role] != nil else { return }
        claims.removeValue(forKey: role)
        _ = applyEffectiveConfiguration()
    }

    /// The role whose configuration is currently winning, if any. Exposed for
    /// tests and for the volume source to decide whether its KVO can trust the
    /// active category.
    var effectiveRole: AudioSessionRole? {
        claims.keys.max { $0.rawValue < $1.rawValue }
    }

    // MARK: - Applying the effective configuration

    /// Compute the highest-priority claim, apply it to the shared session if
    /// it differs from what's applied, and re-arm subscribers when the applied
    /// configuration changes. Returns any activation error.
    @discardableResult
    private func applyEffectiveConfiguration() -> Error? {
        guard let role = effectiveRole, let config = claims[role] else {
            // Nothing wants the session. We intentionally do NOT deactivate —
            // a naked `setActive(false)` can blip the route for whatever the
            // OS falls back to, and there's nothing to gain. Drop the applied
            // marker so the next claim always re-applies + re-arms.
            appliedConfiguration = nil
            return nil
        }

        // Even when the winning configuration is unchanged, a caller may be
        // re-claiming after an interruption where iOS silently deactivated us;
        // re-activating is cheap and idempotent. But only fire the re-arm
        // signal when the applied configuration actually changed, so we don't
        // spam observers on every idempotent recording re-activation.
        let changed = appliedConfiguration != config

        let error = apply(config)
        if error == nil {
            appliedConfiguration = config
        }
        if changed {
            fireReArm()
        }
        return error
    }

    /// Push a configuration onto the real shared session. No-op (returns nil)
    /// in suppressed / test mode.
    private func apply(_ config: AudioSessionConfiguration) -> Error? {
        guard !suppressSessionWork else { return nil }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(config.category, mode: config.mode, options: config.options)
            try session.setActive(true, options: [])
            return nil
        } catch {
            return error
        }
    }

    /// Invoke every registered re-arm handler on the main actor.
    private func fireReArm() {
        for handler in reArmHandlers.values {
            handler()
        }
    }

    // MARK: - Interruption / route-change re-arm

    /// Register once for the notifications that silently invalidate an
    /// `outputVolume` observer: an interruption ending, a route change, or a
    /// media-services reset. On each, re-apply the winning configuration and
    /// re-arm subscribers.
    private func configureNotificationsIfNeeded() {
        guard !notificationsRegistered, !suppressSessionWork else { return }
        notificationsRegistered = true

        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleInterruption(note)
            }
        }

        center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSessionDisruption()
            }
        }

        center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSessionDisruption()
            }
        }
    }

    /// On interruption end, re-apply + re-arm. On interruption begin we do
    /// nothing — iOS has taken the session and there's nothing to re-arm until
    /// it comes back.
    private func handleInterruption(_ note: Notification) {
        guard
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        if type == .ended {
            handleSessionDisruption()
        }
    }

    /// Re-establish the winning configuration on the live session and re-arm
    /// subscribers unconditionally — the observer they hold is presumed dead
    /// after a disruption, so we always want them to rebuild it.
    func handleSessionDisruption() {
        guard effectiveRole != nil else { return }
        // Force a re-apply by clearing the applied marker so the (possibly
        // unchanged) configuration is pushed again and the re-arm fires.
        appliedConfiguration = nil
        _ = applyEffectiveConfiguration()
        // `applyEffectiveConfiguration` fires re-arm because we cleared the
        // marker above (config now "differs" from nil).
    }
}

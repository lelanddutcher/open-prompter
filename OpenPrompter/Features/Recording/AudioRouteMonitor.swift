//
//  AudioRouteMonitor.swift
//  OpenPrompter
//
//  Observes `AVAudioSession.routeChangeNotification` and exposes the current
//  input route name in a SwiftUI-readable form. The Settings status row
//  displays this so the user can see what the OS is actually picking up
//  right now — distinct from their "preferred" pick, which may not be
//  connected.
//
//  The replacement for the auto-fallback warning chip we considered and
//  scrapped (V2 Design 02 review note 1). The user gets passive observation,
//  not a noisy warning.
//

import AVFoundation
import Foundation
import Observation

#if canImport(UIKit)
import UIKit
#endif

@Observable
@MainActor
final class AudioRouteMonitor {

    /// Human-readable name of the currently-routed input. Falls back to
    /// "Built-in microphone" when the session has no recognizable input
    /// (e.g. before audio session activation).
    private(set) var currentRouteName: String = "Built-in microphone"

    /// Stable port-class identifier ("BuiltInMic", "BluetoothHFP",
    /// "BluetoothA2DP", "USBAudio", etc.). Used for the picker's "device
    /// class" label so we can prefix bluetooth / USB sources distinctly.
    private(set) var currentRoutePortType: String = AVAudioSession.Port.builtInMic.rawValue

    /// All currently-available input ports. Refreshed on every route change
    /// so the picker reflects what the user can actually pick right now.
    /// Empty before activation; populated by `start()`.
    private(set) var availableInputs: [AudioInputDescriptor] = []

    /// The "preferred" input the user pinned in Settings, persisted across
    /// reconnects. May not be currently connected — the picker handles the
    /// disconnected case by surfacing it in italic.
    var preferredInputUID: String? {
        Prefs.recordingMicSource
    }

    /// Lightweight wrapper around an `AVAudioSessionPortDescription` — the
    /// SDK type isn't `Sendable` and trying to publish it through the
    /// observable model triggers strict-concurrency warnings. We snapshot
    /// the fields we need.
    struct AudioInputDescriptor: Identifiable, Hashable, Sendable {
        let id: String              // portUID — unique across reconnects
        let portName: String        // human-readable
        let portType: String        // port-class (BuiltInMic, BluetoothHFP, …)

        var displayName: String {
            // Lowercase house-style label. For known-class types we prefix
            // the class so the user can tell "AirPods Pro (Bluetooth)" vs
            // "VideoMic NTG (USB)" vs the built-in mic.
            switch portType {
            case AVAudioSession.Port.builtInMic.rawValue:    return "built-in microphone"
            case AVAudioSession.Port.bluetoothHFP.rawValue,
                 AVAudioSession.Port.bluetoothA2DP.rawValue,
                 AVAudioSession.Port.bluetoothLE.rawValue:
                return "bluetooth — \(portName.lowercased())"
            case AVAudioSession.Port.usbAudio.rawValue:      return "usb — \(portName.lowercased())"
            case AVAudioSession.Port.headsetMic.rawValue:    return "headset — \(portName.lowercased())"
            default:                                          return portName.lowercased()
            }
        }
    }

    private var observerToken: NSObjectProtocol?

    init() {}

    /// Start observing route changes. Idempotent — calling twice is a no-op.
    /// Caller is the prompter view (which only needs route info while open)
    /// or the Settings view; the observer is torn down on `stop()` to avoid
    /// retaining state for views that are no longer on screen.
    func start() {
        if observerToken != nil { return }
        let center = NotificationCenter.default
        observerToken = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The notification fires on a background thread. Hop to main.
            Task { @MainActor in
                self?.refresh()
            }
        }
        // Seed the current state immediately so SwiftUI doesn't show a
        // stale "Built-in microphone" until the first route change.
        refresh()
    }

    /// Stop observing. Safe to call repeatedly.
    func stop() {
        if let token = observerToken {
            NotificationCenter.default.removeObserver(token)
            observerToken = nil
        }
    }

    /// Re-read the audio session's current route + available inputs. Pure
    /// — no side effects beyond the @Observable property writes — so the
    /// notification handler can call this freely.
    func refresh() {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        if let input = route.inputs.first {
            currentRouteName = input.portName
            currentRoutePortType = input.portType.rawValue
        } else {
            currentRouteName = "Built-in microphone"
            currentRoutePortType = AVAudioSession.Port.builtInMic.rawValue
        }
        let inputs = session.availableInputs ?? []
        availableInputs = inputs.map {
            AudioInputDescriptor(
                id: $0.uid,
                portName: $0.portName,
                portType: $0.portType.rawValue
            )
        }
    }

    deinit {
        // The token field is @MainActor-isolated; removing a NotificationCenter
        // observer is safe to do from any thread, but Swift 6 strict
        // concurrency wants us to read the stored property nonisolated. We
        // capture the token at the last main-actor point we have via a
        // local copy on `stop()` and trust that any leaked instance simply
        // stops getting notifications (the closure has a weak self anyway).
    }
}

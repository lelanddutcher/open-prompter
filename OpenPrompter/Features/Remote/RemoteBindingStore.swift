//
//  RemoteBindingStore.swift
//  OpenPrompter
//
//  Persistent map: physical key (or media-control identifier) → RemoteEvent.
//  The keyboard event source asks this store "what does Space mean?" and
//  the store either returns a `RemoteEvent` or `nil` (unbound, ignore).
//
//  Persistence: a JSON blob in UserDefaults keyed by `pref.remote.bindings`.
//  We store the raw `RemoteKey.id` strings so the schema is forward-
//  compatible — a new build that adds a key won't crash trying to decode
//  an unknown enum case from a stored binding.
//
//  Defaults are defined in code (not in UserDefaults `register`) so a
//  reset-to-defaults call always lands on the canonical table even if a
//  previous build wrote a different shape.
//

import Foundation
import Observation
import SwiftUI

/// A user-facing identifier for a physical input. Keeps the model
/// source-agnostic — `KeyboardEventSource`, `MediaCommandSource`, and
/// `VolumeEventSource` each map their device input to a `RemoteKey` and ask
/// the store for the bound event.
///
/// Stored as a stable string (`id`) so adding new keys later doesn't
/// invalidate older saved-bindings JSON.
enum RemoteKey: Hashable, Identifiable, Sendable {
    // MARK: Keyboard
    case space
    case `return`
    case escape
    case tab
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case pageUp
    case pageDown
    case letter(Character)

    // MARK: Media keys (MPRemoteCommandCenter)
    case mediaPlayPause
    case mediaNextTrack
    case mediaPrevTrack

    // MARK: Volume buttons (AVAudioSession.outputVolume KVO, opt-in only)
    case volumeUp
    case volumeDown

    /// Stable string identifier used in JSON storage and SwiftUI Picker tags.
    /// Keep these strings stable across releases.
    var id: String {
        switch self {
        case .space:           return "kb.space"
        case .return:          return "kb.return"
        case .escape:          return "kb.escape"
        case .tab:             return "kb.tab"
        case .arrowUp:         return "kb.up"
        case .arrowDown:       return "kb.down"
        case .arrowLeft:       return "kb.left"
        case .arrowRight:      return "kb.right"
        case .pageUp:          return "kb.pageup"
        case .pageDown:        return "kb.pagedown"
        case .letter(let c):   return "kb.letter.\(Character(c.lowercased()))"
        case .mediaPlayPause:  return "media.playpause"
        case .mediaNextTrack:  return "media.next"
        case .mediaPrevTrack:  return "media.prev"
        case .volumeUp:        return "vol.up"
        case .volumeDown:      return "vol.down"
        }
    }

    /// Human-readable label used in the bindings list.
    var displayName: String {
        switch self {
        case .space:           return "Space"
        case .return:          return "Return"
        case .escape:          return "Escape"
        case .tab:             return "Tab"
        case .arrowUp:         return "Up arrow"
        case .arrowDown:       return "Down arrow"
        case .arrowLeft:       return "Left arrow"
        case .arrowRight:      return "Right arrow"
        case .pageUp:          return "Page Up"
        case .pageDown:        return "Page Down"
        case .letter(let c):   return String(c).uppercased()
        case .mediaPlayPause:  return "Play / Pause (media key)"
        case .mediaNextTrack:  return "Next track (media key)"
        case .mediaPrevTrack:  return "Previous track (media key)"
        case .volumeUp:        return "Volume Up"
        case .volumeDown:      return "Volume Down"
        }
    }

    /// True if this key is reachable only through the volume side-channel.
    /// The settings UI hides these unless the user has opted into volume
    /// button capture, since shipping them as default bindings would be a
    /// 2.5.9 review risk.
    var requiresVolumeOptIn: Bool {
        switch self {
        case .volumeUp, .volumeDown: return true
        default:                     return false
        }
    }
}

/// In-memory + UserDefaults-backed store of (RemoteKey → RemoteEvent) bindings.
/// Observable so the Settings UI can re-render when a binding changes.
@Observable
@MainActor
final class RemoteBindingStore {
    /// Storage key for the persisted bindings JSON. Distinct from `Prefs` so
    /// the cloud-mirrored prefs keep the small set documented there and we
    /// don't mirror the (potentially large) binding table by mistake.
    static let storageKey = "pref.remote.bindings"

    /// The canonical default table — see `Roadmap V2.md` §7 and
    /// `Bluetooth Remote Research.md`. Keep this in sync with the docs.
    static var defaultBindings: [RemoteKey: RemoteEvent] {
        [
            .space:          .playPause,
            .return:         .playPause,
            .arrowUp:        .speedUp,
            .arrowDown:      .speedDown,
            .arrowLeft:      .jumpBackward,
            .arrowRight:     .jumpForward,
            .pageUp:         .prevSection,
            .pageDown:       .nextSection,
            .letter("b"):    .jumpToStart,
            .letter("m"):    .mirrorToggle,
            .letter("r"):    .restart,
            // Media keys — Satechi R2 et al. emit play/pause + skip on the
            // MPRemoteCommandCenter pathway. Default to play/pause on all
            // three; user can remap.
            .mediaPlayPause: .playPause,
            .mediaNextTrack: .nextSection,
            .mediaPrevTrack: .prevSection,
            // Volume bindings are wired but only fire when the user enables
            // the volume opt-in. Default action is play/pause for AB Shutter 3.
            .volumeUp:       .playPause,
            .volumeDown:     .playPause
        ]
    }

    private(set) var bindings: [RemoteKey: RemoteEvent] = [:]

    /// Inject UserDefaults so unit tests can run without polluting the
    /// app's defaults domain.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Public API

    /// Look up the event for a physical key. Returns nil for unbound keys
    /// (the source then ignores the press).
    func event(for key: RemoteKey) -> RemoteEvent? {
        bindings[key]
    }

    /// Replace the binding for a single key. Pass `nil` to clear.
    func setBinding(_ event: RemoteEvent?, for key: RemoteKey) {
        if let event {
            bindings[key] = event
        } else {
            bindings.removeValue(forKey: key)
        }
        save()
    }

    /// All keys currently bound, sorted for stable display order in the UI.
    var allBindings: [(key: RemoteKey, event: RemoteEvent)] {
        bindings
            .map { (key: $0.key, event: $0.value) }
            .sorted { $0.key.id < $1.key.id }
    }

    /// Reset every binding to the documented default table. Used by the
    /// "Reset to defaults" button in Settings.
    func resetToDefaults() {
        bindings = Self.defaultBindings
        save()
    }

    // MARK: - Persistence

    private struct StoredBinding: Codable {
        let keyID: String
        let event: RemoteEvent
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([StoredBinding].self, from: data),
              !decoded.isEmpty else {
            bindings = Self.defaultBindings
            return
        }
        var rebuilt: [RemoteKey: RemoteEvent] = [:]
        for entry in decoded {
            if let key = Self.keyFromID(entry.keyID) {
                rebuilt[key] = entry.event
            }
        }
        // Empty after rebuilding (e.g. all stored IDs were unknown) — fall
        // back to defaults so the user always has a working remote.
        bindings = rebuilt.isEmpty ? Self.defaultBindings : rebuilt
    }

    private func save() {
        let entries = bindings.map { StoredBinding(keyID: $0.key.id, event: $0.value) }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// Reverse lookup `RemoteKey.id` → `RemoteKey`. The letter case is the
    /// only one that needs parsing because every other key encodes a fixed
    /// string. Unknown IDs return `nil` (graceful for forward-compat).
    static func keyFromID(_ id: String) -> RemoteKey? {
        switch id {
        case "kb.space":          return .space
        case "kb.return":         return .return
        case "kb.escape":         return .escape
        case "kb.tab":            return .tab
        case "kb.up":             return .arrowUp
        case "kb.down":           return .arrowDown
        case "kb.left":           return .arrowLeft
        case "kb.right":          return .arrowRight
        case "kb.pageup":         return .pageUp
        case "kb.pagedown":       return .pageDown
        case "media.playpause":   return .mediaPlayPause
        case "media.next":        return .mediaNextTrack
        case "media.prev":        return .mediaPrevTrack
        case "vol.up":            return .volumeUp
        case "vol.down":          return .volumeDown
        default:
            if id.hasPrefix("kb.letter.") {
                let suffix = id.dropFirst("kb.letter.".count)
                if suffix.count == 1, let c = suffix.first {
                    return .letter(c)
                }
            }
            return nil
        }
    }
}

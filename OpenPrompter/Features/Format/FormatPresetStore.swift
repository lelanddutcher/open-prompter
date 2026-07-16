//
//  FormatPresetStore.swift
//  OpenPrompter
//
//  Assembly / typing layer over the Format prompt storage in `Prefs`. Reads
//  the resolved prompt strings (override-or-default) and returns typed
//  `FormatPreset` values the UI binds to; writes edits back through `Prefs`,
//  which applies the "" == default rule so a stale default never freezes
//  into storage. The store owns NO storage of its own — `Prefs` is the
//  single source of truth.
//
//  `@Observable` so the prompt-editor sheet re-renders when a prompt or the
//  custom name changes. `@MainActor` because it reads/writes UserDefaults on
//  behalf of the UI (matches RemoteBindingStore).
//
//  No FoundationModels import: iOS-17-safe.
//

import Foundation
import Observation

@Observable
@MainActor
final class FormatPresetStore {

    /// Bump on every write so SwiftUI views observing the store re-read the
    /// computed `presets` array. (`presets` derives from `Prefs`, which
    /// `@Observable` can't track, so we track this token instead.)
    private var revision: Int = 0

    init() {}

    /// The three presets in a stable order (Format, Cleanup, Custom), each
    /// carrying its resolved prompt and `isEdited` flag.
    var presets: [FormatPreset] {
        _ = revision  // establish the observation dependency
        return [
            preset(for: .format),
            preset(for: .cleanup),
            preset(for: .custom)
        ]
    }

    /// The single preset for a kind, resolved from `Prefs`.
    func preset(for kind: FormatPreset.Kind) -> FormatPreset {
        _ = revision
        switch kind {
        case .format:
            let prompt = Prefs.formatPrompt
            return FormatPreset(
                id: kind.rawValue,
                kind: kind,
                name: FormatPreset.defaultName(for: kind),
                prompt: prompt,
                isEdited: prompt != FormatPreset.Defaults.format
            )
        case .cleanup:
            let prompt = Prefs.cleanupPrompt
            return FormatPreset(
                id: kind.rawValue,
                kind: kind,
                name: FormatPreset.defaultName(for: kind),
                prompt: prompt,
                isEdited: prompt != FormatPreset.Defaults.cleanup
            )
        case .custom:
            let prompt = Prefs.customPrompt
            return FormatPreset(
                id: kind.rawValue,
                kind: kind,
                name: Prefs.formatCustomName,
                prompt: prompt,
                isEdited: prompt != FormatPreset.Defaults.custom
            )
        }
    }

    // MARK: - Mutation

    /// Persist an edited prompt string for a kind. Passing the exact shipped
    /// default clears the override (so a future default change reaches this
    /// user) — the `Prefs` setter handles that comparison.
    func setPrompt(_ prompt: String, for kind: FormatPreset.Kind) {
        switch kind {
        case .format:  Prefs.formatPrompt = prompt
        case .cleanup: Prefs.cleanupPrompt = prompt
        case .custom:  Prefs.customPrompt = prompt
        }
        UbiquitousPrefsMirror.pushToCloud()
        revision &+= 1
    }

    /// Set the Custom preset's display name (built-ins are non-renamable).
    func setCustomName(_ name: String) {
        Prefs.formatCustomName = name
        UbiquitousPrefsMirror.pushToCloud()
        revision &+= 1
    }

    /// Reset a kind's prompt to its shipped default. Writing the default
    /// string clears the stored override.
    func resetToDefault(_ kind: FormatPreset.Kind) {
        setPrompt(FormatPreset.defaultPrompt(for: kind), for: kind)
    }
}

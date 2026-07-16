//
//  FormatPreset.swift
//  OpenPrompter
//
//  A named formatting preset carrying the EXACT instruction string sent to
//  the on-device model. Three presets ship: Format (the headline — spacing,
//  dividers, sparing emphasis), Cleanup (light tidy), and Custom (user-
//  authored). Built-in defaults live as `static let` constants so a later
//  build can improve a default and reach users who never edited it, and so
//  "Reset to default" can restore the shipped string.
//
//  No FoundationModels import: iOS-17-safe. Values only.
//

import Foundation

/// A named formatting preset. `id` / `kind` are stable; `prompt` is the
/// literal model-instruction string the user can view and edit.
struct FormatPreset: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case format   // spacing / dividers / emphasis (the headline)
        case cleanup  // light tidy
        case custom   // user-authored
    }

    /// Stable id — equals `kind.rawValue`. Used as the persistence key and
    /// SwiftUI list tag.
    let id: String
    let kind: Kind
    /// Display name. Editable only for `.custom`; built-ins use a fixed name.
    var name: String
    /// The literal instruction string sent to the model as `instructions`.
    var prompt: String
    /// True when `prompt` differs from the shipped default for this kind.
    var isEdited: Bool

    // MARK: - Shipped defaults

    /// The default display name for a kind.
    static func defaultName(for kind: Kind) -> String {
        switch kind {
        case .format:  return "Format"
        case .cleanup: return "Cleanup"
        case .custom:  return "Custom"
        }
    }

    /// The default prompt string for a kind.
    static func defaultPrompt(for kind: Kind) -> String {
        switch kind {
        case .format:  return Defaults.format
        case .cleanup: return Defaults.cleanup
        case .custom:  return Defaults.custom
        }
    }

    /// Shipped default prompt strings. Kept verbatim from V3 Design 04 §3.2.
    /// The heavy "do not change the words" guardrails are load-bearing: the
    /// intent is FORMAT, not content rewriting.
    enum Defaults {
        static let format = """
        You reformat a spoken-word teleprompter script written in Markdown. \
        Improve readability WITHOUT changing the words. You MUST NOT add, remove, \
        rewrite, summarize, or reorder any sentence or phrase. Keep every word the \
        author wrote, in the same order.

        Only adjust formatting:
        - Put a blank line between distinct sections or ideas.
        - Insert a Markdown horizontal rule (a line of ---) between major \
        sections where it aids visual pacing.
        - Apply **bold** to the single most important phrase in a section and \
        *italics* for light emphasis or spoken stress, where it clearly helps a \
        presenter's eye — sparingly, not on every line.
        - Turn an existing run of parallel points into a Markdown list only if the \
        author clearly already wrote them as a list.
        - Fix obviously broken Markdown (unbalanced ** or _).

        Return ONLY the reformatted Markdown. No preamble, no explanation, no code \
        fences.
        """

        static let cleanup = """
        You lightly tidy a Markdown teleprompter script. Do NOT change wording, \
        add content, or restructure. Only: normalize spacing (collapse 3+ blank \
        lines to one), trim trailing whitespace, ensure exactly one blank line \
        between paragraphs, and fix unbalanced emphasis markers. Do not add \
        dividers, bold, or italics that weren't already there.

        Return ONLY the tidied Markdown. No preamble, no code fences.
        """

        static let custom = """
        Reformat the following Markdown script. Keep all wording exactly as-is and \
        return only Markdown.
        """
    }
}

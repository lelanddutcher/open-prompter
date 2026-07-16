//
//  ScriptFormatting.swift
//  OpenPrompter
//
//  The OS-agnostic seam for the on-device "Format" action (V3 Design 04).
//  This file MUST NOT import FoundationModels — every symbol here compiles
//  down to the app's iOS 17.0 deployment target. The single FoundationModels
//  importer is `SystemModelScriptFormatter` (iOS 26+, gated). Everything the
//  editor UI, the factory, the noop, the mock, and the tests touch lives on
//  this side of the seam so the whole feature builds + degrades on any OS/CI.
//
//  Design intent (verbatim from the design doc): a single button runs the
//  on-device Apple model against the current script with a PRESET prompt to
//  FORMAT it — spacing, dividers, sparing emphasis — WITHOUT changing the
//  words. It mutates the file, guarded by confirm-before-apply + layered
//  undo + a crash stash. Foundation Models must graceful-degrade: never
//  block or crash when the model is unavailable; hide/disable the button
//  with a clear reason.
//

import Foundation

/// Streams cumulative formatted-markdown snapshots for a source script.
///
/// The concrete implementation is chosen at runtime by
/// `ScriptFormatterFactory.make()`: `SystemModelScriptFormatter` on iOS 26+
/// (the only FoundationModels importer), `NoopScriptFormatter` everywhere
/// else. Tests inject `MockScriptFormatter`. Because this protocol carries
/// no FoundationModels types, the editor holds `any ScriptFormatting` and
/// never sees the framework.
protocol ScriptFormatting: Sendable {
    /// Whether formatting can run right now on this device / OS. Read live
    /// on each editor open — availability is not cached (a model download
    /// can finish between launches).
    var availability: FormatAvailability { get }

    /// Stream cumulative formatted-markdown snapshots for `source` using
    /// `prompt` as the model instructions. Each yielded value is the FULL
    /// formatted text so far (snapshot streaming, not deltas), so the final
    /// value is the complete result. Throws `FormatError` on failure and
    /// respects task cancellation (a cancelled stream finishes throwing
    /// `.cancelled`).
    func formatStream(
        source: String,
        prompt: String
    ) -> AsyncThrowingStream<String, Error>
}

/// Runtime availability of the on-device formatter. Mirrors the
/// `SystemLanguageModel.availability` cases but carries no FoundationModels
/// types, so iOS 17 code can switch on it. `SystemModelScriptFormatter`
/// maps the framework enum onto this; `NoopScriptFormatter` reports a fixed
/// reason; the UI decides hide-vs-show-disabled from `isUserFixable`.
enum FormatAvailability: Equatable, Sendable {
    /// Ready to run.
    case available
    /// OS is below iOS 26 — Foundation Models isn't present at all.
    case unavailableOSTooOld
    /// A17 Pro / M-series / ≥8 GB gate not met (`.deviceNotEligible`).
    case unavailableDeviceNotEligible
    /// User-fixable: Apple Intelligence is off in Settings.
    case unavailableAppleIntelligenceOff
    /// The model is downloading / not ready yet.
    case unavailableModelNotReady
    /// Any other framework reason, stringified for diagnostics.
    case unavailableOther(String)
    /// The `labs.format` flag is off — the feature is hidden by choice.
    case unavailableDisabledInLabs

    /// True only when formatting can actually run.
    var isAvailable: Bool { self == .available }

    /// True only for the one case worth showing a DISABLED, tappable button
    /// (tapping surfaces "Turn on Apple Intelligence in Settings"). Every
    /// other unavailable case hides the button entirely.
    var isUserFixable: Bool { self == .unavailableAppleIntelligenceOff }

    /// One-line diagnostic string surfaced in Settings → Labs so the founder
    /// can tell WHY the button is hidden on a given device.
    var diagnosticSummary: String {
        switch self {
        case .available:                       return "available"
        case .unavailableOSTooOld:             return "unavailable — needs iOS 26 or later"
        case .unavailableDeviceNotEligible:    return "unavailable — device not eligible for Apple Intelligence"
        case .unavailableAppleIntelligenceOff: return "unavailable — Apple Intelligence is turned off in Settings"
        case .unavailableModelNotReady:        return "unavailable — model is still downloading"
        case .unavailableOther(let detail):    return "unavailable — \(detail)"
        case .unavailableDisabledInLabs:       return "off in Labs"
        }
    }

    /// Copy shown when the user taps the disabled button (only reachable for
    /// the user-fixable case per `isUserFixable`).
    var userFixHint: String {
        "Turn on Apple Intelligence in Settings to use Format."
    }
}

/// Failure modes of a single format run. No FoundationModels types — the
/// real formatter stringifies the underlying session error into
/// `.underlying`. `Equatable` so tests can assert exact cases.
enum FormatError: Error, Equatable {
    /// The run was cancelled by the user (`Task.cancel()`).
    case cancelled
    /// The model returned empty text — never mutate on this.
    case emptyOutput
    /// The combined instructions + prompt + output exceeded the 4,096-token
    /// window. NEVER apply a truncated result; surface the "format a section
    /// at a time" guidance instead.
    case outputTooLong
    /// The formatter can't run in this device/OS state.
    case unavailable(FormatAvailability)
    /// Any other model / session error, stringified.
    case underlying(String)

    /// User-facing one-liner for the editor's inline error surface.
    var userMessage: String {
        switch self {
        case .cancelled:
            return "Formatting cancelled."
        case .emptyOutput:
            return "The model returned nothing. Your script is unchanged."
        case .outputTooLong:
            return "This script is too long to format on-device. Try formatting a section at a time."
        case .unavailable(let availability):
            return availability.isUserFixable
                ? availability.userFixHint
                : "On-device formatting isn't available on this device."
        case .underlying(let detail):
            return "Formatting failed: \(detail)"
        }
    }
}

/// Heuristics for mapping a stringified model error onto a `FormatError`.
/// Kept as a free function (not a method) so both the real formatter and the
/// tests exercise identical logic — the design doc calls out that a
/// "context exceeded"-shaped error must map to `.outputTooLong` while a
/// generic one maps to `.underlying`.
enum FormatErrorMapper {
    /// Substrings that indicate the on-device context window was exceeded.
    /// The exact wording of the FoundationModels error is verified on-device;
    /// this list is intentionally broad because the mapping only affects the
    /// guidance shown — never whether a truncated result is applied (it never
    /// is).
    private static let contextExceededMarkers = [
        "context",
        "too long",
        "token limit",
        "exceed",
        "window"
    ]

    /// Map a stringified underlying error to a `FormatError`. A description
    /// mentioning the context window becomes `.outputTooLong`; anything else
    /// becomes `.underlying(description)`.
    static func map(description: String) -> FormatError {
        let lowered = description.lowercased()
        if contextExceededMarkers.contains(where: { lowered.contains($0) }) {
            return .outputTooLong
        }
        return .underlying(description)
    }
}

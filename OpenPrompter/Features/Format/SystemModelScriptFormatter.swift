//
//  SystemModelScriptFormatter.swift
//  OpenPrompter
//
//  The ONE file that imports FoundationModels. Gated `@available(iOS 26, *)`
//  and behind `#if canImport(FoundationModels)` so the app still compiles on
//  toolchains / OSes without the framework. Everything outside this file
//  sees only `any ScriptFormatting` — the protocol seam keeps FoundationModels
//  types from leaking into iOS-17 code paths.
//
//  Design decisions (V3 Design 04 §4):
//   - RAW STRING generation, not @Generable. The output is free-form Markdown
//     returned verbatim-but-reformatted; a structured type would fight that.
//   - The PRESET PROMPT becomes the session `instructions` (the rules); the
//     user's SCRIPT is the prompt turn content. "What you edit is what is
//     sent" — the visible prompt string is the instructions, no hidden
//     scaffolding.
//   - Low, fixed temperature (~0.2) — deterministic, conservative formatting,
//     not creativity. Not user-exposed in v1.
//   - Snapshot streaming: yields CUMULATIVE formatted-text snapshots so the
//     UI fills progressively. Access results via `.content` per the framework
//     convention.
//
//  API surface verified on-device by the founder (the simulator lacks Apple
//  Intelligence). The protocol boundary means any SDK-spelling adjustment is
//  contained to this file.
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

@available(iOS 26, *)
struct SystemModelScriptFormatter: ScriptFormatting {

    /// Fixed generation temperature for all presets — low, so formatting is
    /// deterministic and conservative rather than creative.
    private static let temperature = 0.2

    var availability: FormatAvailability {
        // Labs flag is the outermost, cheapest gate — short-circuit before
        // touching the framework.
        if Prefs.labsFormat == false { return .unavailableDisabledInLabs }

        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailableDeviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailableAppleIntelligenceOff
        case .unavailable(.modelNotReady):
            return .unavailableModelNotReady
        case .unavailable(let other):
            // `UnavailableReason` is non-frozen; `let other` catches any
            // reason Apple adds in a future OS without a compile break.
            return .unavailableOther(String(describing: other))
        }
        #else
        // Built against a toolchain without FoundationModels — behave like
        // the noop so nothing calls a missing symbol.
        return .unavailableOSTooOld
        #endif
    }

    func formatStream(source: String, prompt: String)
        -> AsyncThrowingStream<String, Error>
    {
        AsyncThrowingStream { continuation in
            #if canImport(FoundationModels)
            let currentAvailability = availability
            let task = Task {
                do {
                    guard case .available = currentAvailability else {
                        throw FormatError.unavailable(currentAvailability)
                    }
                    // Instructions carry the preset prompt (the rules); the
                    // user's script flows in as the turn content.
                    let session = LanguageModelSession(instructions: prompt)
                    let options = GenerationOptions(temperature: Self.temperature)
                    let responseStream = session.streamResponse(
                        to: source,
                        options: options
                    )
                    for try await partial in responseStream {
                        try Task.checkCancellation()
                        // `.content` is the cumulative String snapshot.
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: FormatError.cancelled)
                } catch let formatError as FormatError {
                    continuation.finish(throwing: formatError)
                } catch {
                    // Map "context exceeded"-shaped errors to `.outputTooLong`
                    // so the UI shows the "format a section at a time"
                    // guidance; everything else is `.underlying`.
                    continuation.finish(
                        throwing: FormatErrorMapper.map(
                            description: error.localizedDescription
                        )
                    )
                }
            }
            continuation.onTermination = { _ in task.cancel() }
            #else
            continuation.finish(throwing: FormatError.unavailable(.unavailableOSTooOld))
            #endif
        }
    }
}

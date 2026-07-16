//
//  NoopScriptFormatter.swift
//  OpenPrompter
//
//  The always-unavailable formatter. Used on iOS < 26 (where FoundationModels
//  doesn't exist) and as the default injected instance in previews / tests
//  that don't want a real model. Reports a fixed availability reason and its
//  `formatStream` finishes immediately throwing `.unavailable(reason)` — it
//  NEVER blocks and NEVER mutates.
//
//  No FoundationModels import: this compiles down to iOS 17.
//

import Foundation

struct NoopScriptFormatter: ScriptFormatting {
    let reason: FormatAvailability

    /// Default to "OS too old" — the most common reason this type is the one
    /// selected by the factory (any device below iOS 26).
    init(reason: FormatAvailability = .unavailableOSTooOld) {
        self.reason = reason
    }

    var availability: FormatAvailability { reason }

    func formatStream(source: String, prompt: String)
        -> AsyncThrowingStream<String, Error>
    {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: FormatError.unavailable(reason))
        }
    }
}

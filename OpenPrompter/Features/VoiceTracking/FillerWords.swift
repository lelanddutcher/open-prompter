//
//  FillerWords.swift
//  OpenPrompter
//
//  V2 Feature 5 — Voice-Tracked Auto-Scroll.
//
//  Configurable set of speech disfluencies stripped from the recognized
//  buffer before alignment. Default set is deliberately conservative:
//  only words that are NOT also valid script vocabulary are included.
//
//  Casual-speech fillers like "like", "so", "actually", "you know" are
//  intentionally OMITTED from the default — they're legitimate script
//  words often enough that blind stripping would mismatch real speech
//  to the script. Callers wanting more aggressive stripping can pass
//  their own set.
//
//  See V2 Design 03 — Voice Tracking.md §"Algorithm" step 3.
//

import Foundation

public enum FillerWords {

    /// Default English filler set. All entries lowercase. Conservative
    /// by design — see file header.
    public static let englishDefault: Set<String> = [
        "um",
        "uh",
        "ah",
        "er",
        "erm",
        "hmm",
        "mhm",
        "huh",
        "uhm",
        "uhh",
        "umm"
    ]

    /// Remove filler tokens from a sequence of words. Comparison is
    /// case-insensitive; non-filler words preserve their original casing
    /// and order.
    public static func strip(
        _ words: [String],
        using fillers: Set<String> = englishDefault
    ) -> [String] {
        guard !fillers.isEmpty else { return words }
        return words.filter { !fillers.contains($0.lowercased()) }
    }
}

//
//  FormatTokenBudget.swift
//  OpenPrompter
//
//  Pre-flight length check for the on-device Format action. The on-device
//  model has a 4,096-token window covering instructions + prompt + output.
//  A long script plus its formatted copy can blow this, and the design doc
//  forbids applying a truncated result. We refuse to run BEFORE invoking the
//  model when the estimate for instructions + source is near the ceiling.
//
//  No FoundationModels import — this is the iOS-17-safe seam. The estimate is
//  a cheap character-based proxy (~4 chars / token) with headroom reserved
//  for the model's own output. If the SDK later exposes a tokenizer we can
//  refine `estimatedTokens` without touching callers.
//

import Foundation

enum FormatTokenBudget {
    /// The on-device model's combined context window (instructions + prompt
    /// + output), per the FoundationModels docs.
    static let contextWindowTokens = 4096

    /// Cheap upper-ish proxy: ~4 characters per token for English prose.
    /// Deliberately conservative — over-counting refuses a borderline script
    /// rather than letting the model truncate the tail.
    static let charactersPerToken = 4

    /// Reserve for the model's OWN output. A reformat produces roughly the
    /// same length as the input plus a little for inserted blank lines and
    /// dividers, so the input must fit in well under half the window. We
    /// budget the input to at most ~45% of the window and leave the rest for
    /// instructions + generated output.
    static let inputBudgetFraction = 0.45

    /// Estimated token count of `text` using the character proxy.
    static func estimatedTokens(for text: String) -> Int {
        // Round up so a short-but-nonempty string never estimates to zero.
        (text.count + charactersPerToken - 1) / charactersPerToken
    }

    /// Max input tokens we allow before refusing to run.
    static var inputTokenBudget: Int {
        Int(Double(contextWindowTokens) * inputBudgetFraction)
    }

    /// Whether `instructions` + `source` are short enough to attempt a run.
    /// Both strings count against the input budget; the remaining window is
    /// reserved for the generated output.
    static func fitsBudget(source: String, instructions: String) -> Bool {
        let combined = estimatedTokens(for: source) + estimatedTokens(for: instructions)
        return combined <= inputTokenBudget
    }

    /// Approximate number of words the source is OVER the limit, for the
    /// "about N words over the limit" guidance. Returns 0 when within budget.
    /// Uses ~0.75 words/token (the inverse of the ~1.33 tokens/word English
    /// average) to phrase the overage in words the user understands.
    static func wordsOverLimit(source: String, instructions: String) -> Int {
        let combined = estimatedTokens(for: source) + estimatedTokens(for: instructions)
        let overageTokens = combined - inputTokenBudget
        guard overageTokens > 0 else { return 0 }
        return Int((Double(overageTokens) * 0.75).rounded(.up))
    }
}

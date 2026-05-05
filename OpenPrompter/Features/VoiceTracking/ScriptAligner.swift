//
//  ScriptAligner.swift
//  OpenPrompter
//
//  V2 Feature 5 — Voice-Tracked Auto-Scroll.
//
//  Pure-function fuzzy matcher that aligns a sliding window of
//  recently-recognized speech words to a position in the user's
//  tokenized script. Caller (`VoiceTracker`) drives state — passes the
//  current cursor and recognized buffer; `align(...)` returns a new
//  cursor (or "no match, hold").
//
//  Scoring (per candidate alignment position):
//      raw_sim       = (1 - editDistance/N) + phoneticBonus * phoneticRatio
//      locality_fac  = 1/(1 + locality * distanceFromCursor)   (or 1 widened)
//      penalized     = raw_sim * locality_fac
//      effective     = penalized - (isBackward ? forwardBias : 0)
//      accept iff effective >= matchThreshold
//
//  Cursor semantic: cursor INDEX points at the next expected token —
//  one past the last matched word. After matching script[k..<k+N] the
//  cursor becomes k+N.
//
//  See V2 Design 03 — Voice Tracking.md §"Algorithm".
//

import Foundation

// MARK: - Public types

public struct ScriptToken: Equatable, Sendable {
    /// Lowercased letters+digits, punctuation stripped.
    public let normalized: String
    /// Phonetic key from `PhoneticEncoder`.
    public let phonetic: String
    /// 0-based position in the token array.
    public let originalIndex: Int
    /// Offset of the token's first character in the raw input string.
    /// Counts characters (not UTF-8 bytes) — usable as a String.Index
    /// distance via `index(_:offsetBy:)`.
    public let charOffset: Int
}

public struct AlignerConfig: Sendable {
    /// Cap recognizedBuffer to this many trailing words for scoring.
    public var windowSize: Int = 6
    /// Tokens to scan before the current cursor (for tight retakes).
    public var lookBack: Int = 10
    /// Tokens to scan after the current cursor (for paragraph skips).
    public var lookAhead: Int = 50
    /// Minimum effective score required to accept a match.
    public var matchThreshold: Double = 0.65
    /// Locality penalty coefficient. Larger → stronger preference for
    /// matches near the cursor. Set to 0 internally when widening.
    public var locality: Double = 0.02
    /// Subtracted from a backward candidate's score before threshold
    /// check. Larger → harder to accept backward retakes.
    public var forwardBias: Double = 0.35
    /// Maximum bonus for a perfect phonetic match across the window.
    public var phoneticBonus: Double = 0.1
    /// Seconds without a match before the search widens to the full
    /// script (handles `User skips entire section` case).
    public var widenTimeout: TimeInterval = 5.0

    /// Cap on the widened search window so a brief loss of tracking
    /// can't teleport the cursor across the entire script when a
    /// generic word ("the", "and") matches at a far position. Widening
    /// ALWAYS expands the window past `lookBack`/`lookAhead`, but never
    /// past these caps.
    public var widenedLookBack: Int = 50
    public var widenedLookAhead: Int = 150

    public init() {}
}

public struct AlignmentResult: Equatable, Sendable {
    /// New cursor on match, or the unchanged input cursor on no match.
    public let cursorIndex: Int
    /// `penalized_sim` of the best candidate. Approximate range
    /// `[0, 1+phoneticBonus]`. NOT reduced by forwardBias — that's a
    /// gating, not a similarity measure.
    public let confidence: Double
    /// True iff the best candidate's effective score crossed
    /// `matchThreshold`.
    public let matched: Bool
    /// Human-readable diagnostic string. Always populated.
    public let rationale: String
}

// MARK: - ScriptAligner

public struct ScriptAligner: Sendable {
    public let tokens: [ScriptToken]
    public let config: AlignerConfig

    public init(tokens: [ScriptToken], config: AlignerConfig = AlignerConfig()) {
        self.tokens = tokens
        self.config = config
    }

    /// Tokenize a raw script. Strips punctuation and whitespace; keeps
    /// letters and digits. Empty / punctuation-only input returns `[]`.
    public static func tokenize(_ text: String) -> [ScriptToken] {
        var tokens: [ScriptToken] = []
        var inWord = false
        var wordStart = 0
        var wordChars: [Character] = []

        func finalize() {
            if !wordChars.isEmpty {
                let normalized = String(wordChars).lowercased()
                let phonetic = PhoneticEncoder.encode(normalized)
                tokens.append(ScriptToken(
                    normalized: normalized,
                    phonetic: phonetic,
                    originalIndex: tokens.count,
                    charOffset: wordStart
                ))
            }
            wordChars = []
            inWord = false
        }

        for (offset, ch) in text.enumerated() {
            if ch.isLetter || ch.isNumber {
                if !inWord {
                    inWord = true
                    wordStart = offset
                }
                wordChars.append(ch)
            } else if ch == "'" {
                // Apostrophe inside a word is silently dropped — "they're"
                // becomes "theyre" so its phonetic encoding folds onto
                // "their" and "there".
                if !inWord {
                    inWord = true
                    wordStart = offset + 1  // skip the apostrophe itself
                }
                // skip — don't append
            } else {
                if inWord {
                    finalize()
                }
            }
        }
        if inWord {
            finalize()
        }

        return tokens
    }

    /// Find the best alignment for `recognizedBuffer` near `cursorIndex`.
    /// Returns the new cursor on a match, or the unchanged cursor with
    /// `matched: false` if no candidate cleared the threshold.
    ///
    /// `visibleRange`, when supplied, OVERRIDES the cursor-relative
    /// search window (cursor ± lookBack/lookAhead) and forces the
    /// aligner to consider only tokens in that range. Used by the view
    /// layer to constrain matches to what's currently on screen, so a
    /// generic word ("the", "and") can never teleport the cursor to an
    /// offscreen instance.
    public func align(
        recognizedBuffer: [String],
        cursorIndex: Int,
        elapsedSinceLastMatch: TimeInterval = 0,
        visibleRange: Range<Int>? = nil
    ) -> AlignmentResult {
        guard !recognizedBuffer.isEmpty else {
            return AlignmentResult(
                cursorIndex: cursorIndex,
                confidence: 0,
                matched: false,
                rationale: "empty buffer"
            )
        }
        guard !tokens.isEmpty else {
            return AlignmentResult(
                cursorIndex: cursorIndex,
                confidence: 0,
                matched: false,
                rationale: "empty script"
            )
        }

        // Cap to the last `windowSize` recognized words; lowercase to
        // match `ScriptToken.normalized`.
        let bufN = min(recognizedBuffer.count, config.windowSize)
        let buf: [String] = recognizedBuffer
            .suffix(bufN)
            .map { $0.lowercased() }
        let bufPhonetic: [String] = buf.map { PhoneticEncoder.encode($0) }

        // Search window — when the view layer supplies `visibleRange`,
        // that range IS the window. Otherwise fall back to the cursor-
        // relative window with optional widening on quiet periods.
        let widened = elapsedSinceLastMatch > config.widenTimeout
        let lookBack = widened
            ? min(config.widenedLookBack, cursorIndex)
            : config.lookBack
        let lookAhead = widened
            ? min(config.widenedLookAhead, max(0, tokens.count - cursorIndex))
            : config.lookAhead
        let searchStart: Int
        let searchEnd: Int
        if let visible = visibleRange {
            searchStart = max(0, visible.lowerBound)
            searchEnd = min(tokens.count, visible.upperBound)
        } else {
            searchStart = max(0, cursorIndex - lookBack)
            searchEnd = min(tokens.count, cursorIndex + lookAhead)
        }
        let lastCandidate = searchEnd - bufN

        guard lastCandidate >= searchStart else {
            return AlignmentResult(
                cursorIndex: cursorIndex,
                confidence: 0,
                matched: false,
                rationale: "search window [\(searchStart),\(searchEnd)) too small for buffer length \(bufN)"
            )
        }

        let activeLocality = widened ? 0.0 : config.locality

        var bestPenalized: Double = 0
        var bestEffective: Double = -.infinity
        var bestCandidate = -1
        var bestDist: Int = bufN
        var bestPhoneticRatio: Double = 0

        for cand in searchStart...lastCandidate {
            let scriptSlice = (cand..<cand + bufN).map { tokens[$0] }
            let scriptWords = scriptSlice.map { $0.normalized }
            let scriptPhonetic = scriptSlice.map { $0.phonetic }

            let dist = wordLevenshtein(scriptWords, buf)
            let normSim = 1.0 - Double(dist) / Double(bufN)

            var phoneticMatches = 0
            for i in 0..<bufN where scriptPhonetic[i] == bufPhonetic[i] {
                phoneticMatches += 1
            }
            let phoneticRatio = Double(phoneticMatches) / Double(bufN)
            let rawSim = normSim + config.phoneticBonus * phoneticRatio

            let cursorDistance = abs(cand - cursorIndex)
            let localityFactor = 1.0 / (1.0 + activeLocality * Double(cursorDistance))
            let penalized = rawSim * localityFactor

            let isBackward = cand < cursorIndex
            let effective = penalized - (isBackward ? config.forwardBias : 0)

            if effective > bestEffective {
                bestEffective = effective
                bestPenalized = penalized
                bestCandidate = cand
                bestDist = dist
                bestPhoneticRatio = phoneticRatio
            }
        }

        if bestEffective >= config.matchThreshold {
            let direction = bestCandidate < cursorIndex ? "backward" : "forward"
            let rationale =
                "matched script[\(bestCandidate)..<\(bestCandidate + bufN)] (\(direction)) " +
                "raw=\(fmt(bestPenalized)) effective=\(fmt(bestEffective)) " +
                "dist=\(bestDist) phonetic=\(fmt(bestPhoneticRatio)) " +
                "widened=\(widened)"
            return AlignmentResult(
                cursorIndex: bestCandidate + bufN,
                confidence: max(0, bestPenalized),
                matched: true,
                rationale: rationale
            )
        } else {
            let rationale =
                "no match — best effective \(fmt(bestEffective)) < threshold " +
                "\(fmt(config.matchThreshold)) at candidate \(bestCandidate) " +
                "(raw=\(fmt(bestPenalized)) widened=\(widened))"
            return AlignmentResult(
                cursorIndex: cursorIndex,
                confidence: max(0, bestPenalized),
                matched: false,
                rationale: rationale
            )
        }
    }

    // MARK: - Internals

    /// Word-level Levenshtein. Each operation (insert / delete /
    /// substitute) is on a whole word.
    private func wordLevenshtein(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            for k in 0...b.count { prev[k] = curr[k] }
        }
        return prev[b.count]
    }

    private func fmt(_ x: Double) -> String {
        String(format: "%.3f", x)
    }
}

//
//  ScriptBiasVocabulary.swift
//  OpenPrompter
//
//  V3 Design 05 — SpeechAnalyzer Biasing, Slice A (ships ALL iOS versions).
//
//  A pure, `Sendable`, version-agnostic extractor that pulls the most
//  DISTINCTIVE tokens from the loaded script — proper nouns, acronyms,
//  product/version terms, CamelCase brand names, and long domain jargon —
//  and returns them as contextual-bias strings for the speech recognizer.
//
//  Why: the shipped SF path (VoiceTracker.start) used a ~100-word window
//  NEAR THE CURSOR as `contextualStrings`. That window is polluted with
//  generic filler ("the", "and", "that") that wastes the recognizer's
//  bias budget and does nothing for accuracy. This extractor replaces
//  that snapshot with a distinctiveness-ranked set: the recognizer locks
//  onto exactly the words the Soundex/metaphone aligner most often has to
//  paper over.
//
//  Design contract (V3 Design 05 §2):
//    • No Speech import. Fully unit-testable, mirrors PhoneticEncoder /
//      FillerWords pure-function style.
//    • Returns ORIGINAL-cased surface forms (e.g. "Kubernetes",
//      "OpenPrompter", "Q3") — biasing wants the spelling the ASR should
//      prefer, not the aligner's normalized lowercased form.
//    • Deterministic: same input always yields the same ordered array.
//      No `Set` iteration for ordering (Set order is nondeterministic);
//      de-dupe via an ordered pass with a seen-set for membership only.
//    • Excludes fillers + stopwords so a script that's all function words
//      contributes NOTHING (same as an empty window today — no crash, no
//      behavioral cliff).
//
//  See V3 Design 05 — SpeechAnalyzer Biasing.md §2.
//

import Foundation

public enum ScriptBiasVocabulary {

    /// Extract up to `cap` distinctive contextual-bias strings from a
    /// script body. Deterministic, pure. Empty / all-stopword input → [].
    ///
    /// Ranked by a distinctiveness score (proper nouns, acronyms,
    /// digit-bearing product terms, CamelCase, and long rare words score
    /// highest). De-duped case-insensitively, preserving the first-seen
    /// surface form. Multi-word Proper Noun Phrases (2–3 consecutive
    /// mid-sentence capitalized tokens, e.g. "New York Times") are emitted
    /// as a single phrase hint in addition to their component tokens — a
    /// phrase hint is a stronger prior for both SFSpeechRecognizer and
    /// SpeechTranscriber.
    public static func extract(from body: String, cap: Int = 100) -> [String] {
        guard !body.isEmpty else { return [] }

        // Phase 1: split the body into surface tokens, tracking for each
        // token whether it is sentence-initial (the previous token ended a
        // sentence, or it's the first token of the body). Sentence-initial
        // capitalization is NOT a proper-noun signal.
        let surfaceTokens = splitSurfaceTokens(body)
        guard !surfaceTokens.isEmpty else { return [] }

        // Phase 2: score every eligible single token. Excluded tokens
        // (fillers, stopwords, too-short, bare small numerics) are dropped.
        // We keep the FIRST appearance order so ties break deterministically.
        struct Scored {
            let surface: String        // original-cased, first-seen form
            let score: Int
            let components: Int        // number of positive signals (tie-break)
            let firstAppearance: Int   // stable ordering (tie-break)
        }

        var scored: [Scored] = []
        var seenLowercased: Set<String> = []
        var appearanceCounter = 0

        for st in surfaceTokens {
            let lowered = st.text.lowercased()
            // Case-insensitive de-dupe: emit each distinct token ONCE,
            // keeping the first-seen surface form. Frequency does NOT boost
            // (a common domain word said 40× is worth exactly one entry —
            // boosting frequency re-introduces the "the appears 40 times"
            // failure mode).
            if seenLowercased.contains(lowered) { continue }

            guard let (score, components) = scoreToken(
                surface: st.text,
                lowered: lowered,
                isSentenceInitial: st.isSentenceInitial
            ) else {
                // Hard-excluded (filler / stopword / too short / bare numeric).
                // Do NOT add to seen — an excluded surface can't later block a
                // distinct eligible token, and it never emits regardless.
                continue
            }

            seenLowercased.insert(lowered)
            scored.append(Scored(
                surface: st.text,
                score: score,
                components: components,
                firstAppearance: appearanceCounter
            ))
            appearanceCounter += 1
        }

        // Phase 3: extract multi-word proper-noun phrases (2–3 consecutive
        // mid-sentence capitalized tokens). Emit each distinct phrase once,
        // ranked with a strong phrase score so a "New York Times"-style
        // hint sits near the top. Phrases are appended to the same ranking
        // pool and de-duped independently of the single-token pool (a phrase
        // and its component word are different bias strings).
        let phrases = extractProperNounPhrases(surfaceTokens)
        var phraseSeen: Set<String> = []
        for phrase in phrases {
            let key = phrase.lowercased()
            if phraseSeen.contains(key) { continue }
            phraseSeen.insert(key)
            scored.append(Scored(
                surface: phrase,
                // Phrase score = proper-noun signal (+3) per word, so a
                // 3-word phrase outranks any single-token proper noun. Cap
                // the components so tie-breaks still favor real multi-signal
                // single tokens when scores are equal.
                score: properNounSignal * phrase.split(separator: " ").count,
                components: 2,
                firstAppearance: appearanceCounter
            ))
            appearanceCounter += 1
        }

        // Phase 4: stable sort by (score desc, components desc, firstAppearance
        // asc) then take the top `cap`. Swift's `sort` is not guaranteed
        // stable, so encode the full ordering in the comparator — this makes
        // the result deterministic and testable.
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.components != b.components { return a.components > b.components }
            return a.firstAppearance < b.firstAppearance
        }

        return scored.prefix(cap).map { $0.surface }
    }

    // MARK: - Scoring

    /// Proper-noun signal weight, exposed so the phrase scorer can reuse it.
    private static let properNounSignal = 3

    /// Score a single token. Returns `nil` for hard-excluded tokens (never
    /// emitted). Otherwise returns `(score, positiveSignalCount)`. Higher
    /// score = more distinctive = more worth biasing.
    ///
    /// Score components (V3 Design 05 §2.2):
    ///   +3  proper noun (capitalized AND not sentence-initial)
    ///   +3  all-caps acronym (≥2 letters, all uppercase) or dotted acronym
    ///   +2  CamelCase / internal caps (uppercase after a lowercase letter)
    ///   +2  length ≥ 13   (disproportionately domain jargon)
    ///   +1  length ≥ 9
    ///   +1  digit-bearing (mixed alphanumerics: product / version terms)
    /// Baseline eligibility: any non-excluded token of len ≥ 4 → score 0.
    private static func scoreToken(
        surface: String,
        lowered: String,
        isSentenceInitial: Bool
    ) -> (score: Int, components: Int)? {
        // Hard exclusions ----------------------------------------------------
        let scalars = Array(surface.unicodeScalars)
        let charCount = surface.count

        // Pure single-character tokens are noise.
        if charCount < 2 { return nil }

        // Filler set (shared with FillerWords so the two stay in sync).
        if FillerWords.englishDefault.contains(lowered) { return nil }

        // Stopword set — the guard that stops the old locality window from
        // wasting bias budget on "the" / "and" / "of".
        if stopwords.contains(lowered) { return nil }

        let hasLetter = surface.contains { $0.isLetter }
        let hasDigit = surface.contains { $0.isNumber }

        // Purely-numeric tokens: keep only len ≥ 4 (e.g. "2026" is a useful
        // year; bare "5" / "42" are noise). "Numeric" here means no letters.
        if !hasLetter {
            if charCount < 4 { return nil }
        }

        // Baseline eligibility: non-excluded token of len ≥ 4 is eligible at
        // score 0. Tokens of len 2–3 are only eligible if they carry a
        // distinctive signal (acronym / proper noun / camelcase) — otherwise
        // a bare 2–3 char non-stopword (e.g. "app") would flood the list.
        // We compute signals first, then apply this floor.

        // Signals ------------------------------------------------------------
        var score = 0
        var components = 0

        // Proper-noun signal: first letter uppercase, remainder not all
        // uppercase (that's the acronym case), AND not sentence-initial.
        let firstIsUpper = surface.first?.isUppercase ?? false
        let isAllUpperLetters = hasLetter && surface.allSatisfy { !$0.isLetter || $0.isUppercase }

        if firstIsUpper && !isAllUpperLetters && !isSentenceInitial && hasLetter {
            score += properNounSignal
            components += 1
        }

        // Acronym signal: all-caps run of ≥2 letters ("API", "SDK", "NASA"),
        // or a dotted acronym shape ("U.S.", "A.I.") where the letters are
        // uppercase and dots separate single letters.
        if isAllUpperLetters && surface.filter({ $0.isLetter }).count >= 2 {
            score += 3
            components += 1
        } else if isDottedAcronym(surface) {
            score += 3
            components += 1
        }

        // CamelCase / internal-caps: an uppercase letter that follows a
        // lowercase letter ("OpenPrompter", "SwiftUI", "eBay").
        if hasInternalCaps(scalars) {
            score += 2
            components += 1
        }

        // Rarity by length.
        if charCount >= 13 {
            score += 2
            components += 1
        } else if charCount >= 9 {
            score += 1
            components += 1
        }

        // Digit-bearing mixed alphanumerics ("iPhone17", "Q3", "COVID19").
        if hasLetter && hasDigit {
            score += 1
            components += 1
        }

        // Eligibility floor: a token with NO positive signal is only kept if
        // it is a real content word of len ≥ 4. This keeps plain-English
        // scripts contributing their longer content words (baseline biasing)
        // while excluding short function-ish words that dodged the stopword
        // list.
        if components == 0 && charCount < 4 { return nil }

        return (score, components)
    }

    // MARK: - Token splitting

    /// A surface token plus whether it starts a sentence (previous token
    /// ended with sentence punctuation, or it's the body's first token).
    private struct SurfaceToken {
        let text: String
        let isSentenceInitial: Bool
    }

    /// Split the body into surface tokens. A candidate token is a maximal run
    /// of letters/digits plus internal `'`, `-`, `.` (so "state-of-the-art",
    /// "U.S.", "v3.0" survive as single tokens). Leading/trailing
    /// punctuation is trimmed. Sentence-initial detection tracks the
    /// PREVIOUS raw token's trailing sentence punctuation (`.`, `!`, `?`,
    /// `:`, `;`) or start-of-body.
    private static func splitSurfaceTokens(_ body: String) -> [SurfaceToken] {
        var out: [SurfaceToken] = []
        var current = String.UnicodeScalarView()
        // The NEXT emitted token starts a sentence (start-of-body counts).
        var nextIsSentenceInitial = true

        func isInternalConnector(_ s: Unicode.Scalar) -> Bool {
            s == "'" || s == "-" || s == "." || s == "\u{2019}" // curly apostrophe
        }
        func isWordScalar(_ s: Unicode.Scalar) -> Bool {
            CharacterSet.alphanumerics.contains(s)
        }
        func isSentenceEnder(_ s: Unicode.Scalar) -> Bool {
            s == "." || s == "!" || s == "?" || s == ":" || s == ";"
        }

        func flush() {
            guard !current.isEmpty else { return }
            // Trim leading/trailing connectors so "U.S." keeps its internal
            // dots but a token that captured a stray leading/trailing dot is
            // cleaned. (A sentence-ending period is handled at the boundary
            // below, so it never lands inside `current`.)
            var scalars = Array(current)
            while let first = scalars.first, isInternalConnector(first) {
                scalars.removeFirst()
            }
            while let last = scalars.last, isInternalConnector(last) {
                scalars.removeLast()
            }
            let text = String(String.UnicodeScalarView(scalars))
            if !text.isEmpty {
                out.append(SurfaceToken(
                    text: text,
                    isSentenceInitial: nextIsSentenceInitial
                ))
                // Default: the following token is NOT sentence-initial. A
                // sentence ender (handled below) flips this back to true.
                nextIsSentenceInitial = false
            }
            current = String.UnicodeScalarView()
        }

        // Index the scalars so we can peek at the NEXT scalar to disambiguate
        // an internal dot (acronym / decimal — followed by a letter/digit)
        // from a sentence-ending period (followed by whitespace / end).
        let scalars = Array(body.unicodeScalars)
        for (i, scalar) in scalars.enumerated() {
            let next: Unicode.Scalar? = (i + 1 < scalars.count) ? scalars[i + 1] : nil

            if scalar == "." {
                // A dot is INTERNAL only when the next scalar is a word char
                // (e.g. "U.S", "v3.0"); otherwise it's a sentence ender.
                if let n = next, isWordScalar(n) {
                    current.append(scalar)
                } else {
                    flush()
                    nextIsSentenceInitial = true
                }
                continue
            }

            if isWordScalar(scalar) || isInternalConnector(scalar) {
                current.append(scalar)
            } else {
                // Non-word boundary. Close any token in progress.
                flush()
                if isSentenceEnder(scalar) {
                    nextIsSentenceInitial = true
                } else if scalar == "\n" {
                    // A newline is a soft sentence boundary (headings, list
                    // items) so a capitalized first word of a new line is
                    // sentence-initial, not a proper noun.
                    nextIsSentenceInitial = true
                }
            }
        }
        flush()
        return out
    }

    // MARK: - Multi-word proper-noun phrases

    /// Extract 2–3 word runs of consecutive mid-sentence capitalized tokens.
    /// "the New York Times reported" → "New York Times". The runs are joined
    /// with single spaces and returned in first-appearance order. Sentence-
    /// initial capitalization does NOT start a phrase (so "Today we ran."
    /// doesn't emit "Today we").
    private static func extractProperNounPhrases(_ tokens: [SurfaceToken]) -> [String] {
        var phrases: [String] = []
        var run: [String] = []

        func closeRun() {
            if run.count >= 2 {
                // Emit the full run (capped at 3 words: a longer run is
                // unusual and a 3-gram is already a strong hint).
                let capped = Array(run.prefix(3))
                phrases.append(capped.joined(separator: " "))
            }
            run = []
        }

        for st in tokens {
            let firstIsUpper = st.text.first?.isUppercase ?? false
            let isAllUpper = st.text.contains { $0.isLetter } &&
                st.text.allSatisfy { !$0.isLetter || $0.isUppercase }
            // A phrase member is a capitalized-but-not-all-caps mid-sentence
            // token. Sentence-initial tokens break the run (they start a new
            // sentence, not a name phrase).
            let isProperNounMember = firstIsUpper && !isAllUpper && !st.isSentenceInitial

            if isProperNounMember {
                run.append(st.text)
                if run.count == 3 {
                    // Emit and reset so a long list of names yields 3-grams
                    // deterministically rather than one giant phrase.
                    closeRun()
                }
            } else {
                closeRun()
            }
        }
        closeRun()
        return phrases
    }

    // MARK: - Helpers

    /// True when `surface` contains an uppercase letter immediately after a
    /// lowercase letter — CamelCase / internal-caps.
    private static func hasInternalCaps(_ scalars: [Unicode.Scalar]) -> Bool {
        guard scalars.count >= 2 else { return false }
        for i in 1..<scalars.count {
            let prev = Character(scalars[i - 1])
            let cur = Character(scalars[i])
            if prev.isLowercase && cur.isUppercase { return true }
        }
        return false
    }

    /// True for a dotted-acronym shape: alternating single uppercase letters
    /// and dots, e.g. "U.S.", "A.I.", "U.S.A". At least two letters.
    private static func isDottedAcronym(_ surface: String) -> Bool {
        guard surface.contains(".") else { return false }
        let letters = surface.filter { $0.isLetter }
        guard letters.count >= 2 else { return false }
        // Every letter must be uppercase and every non-dot char must be a
        // letter (dots are the only allowed separators).
        for ch in surface {
            if ch == "." { continue }
            if !ch.isLetter || !ch.isUppercase { return false }
        }
        return true
    }

    // MARK: - Stopwords

    /// Top ~150 English function words. Lowercased. These are excluded from
    /// biasing entirely — biasing toward "the" wastes budget and never helps
    /// recognition. Kept as a `Set` for O(1) membership (never iterated for
    /// ordering, so Set nondeterminism can't leak into the output).
    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "nor", "for", "so", "yet",
        "of", "to", "in", "on", "at", "by", "with", "from", "as", "into",
        "onto", "upon", "over", "under", "above", "below", "up", "down",
        "out", "off", "about", "against", "between", "through", "during",
        "before", "after", "than", "then", "once", "here", "there", "when",
        "where", "why", "how", "all", "any", "both", "each", "few", "more",
        "most", "other", "some", "such", "only", "own", "same", "too", "very",
        "is", "are", "was", "were", "be", "been", "being", "am", "have",
        "has", "had", "do", "does", "did", "doing", "done", "will", "would",
        "shall", "should", "can", "could", "may", "might", "must", "ought",
        "i", "me", "my", "mine", "we", "us", "our", "ours", "you", "your",
        "yours", "he", "him", "his", "she", "her", "hers", "it", "its",
        "they", "them", "their", "theirs", "this", "that", "these", "those",
        "who", "whom", "whose", "which", "what", "not", "no", "yes", "if",
        "because", "while", "although", "though", "unless", "until", "since",
        "whether", "either", "neither", "just", "now", "also", "even", "still",
        "back", "well", "way", "get", "got", "go", "going", "let", "make",
        "made", "see", "come", "came", "take", "took", "one", "two", "three",
        "first", "next", "last", "much", "many", "lot", "lots", "thing",
        "things", "like", "want", "need", "know", "think", "really", "quite",
        "here's", "there's", "let's", "im", "youre", "dont", "cant", "its"
    ]
}

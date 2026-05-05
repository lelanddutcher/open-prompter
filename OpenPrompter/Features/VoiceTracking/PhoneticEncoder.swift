//
//  PhoneticEncoder.swift
//  OpenPrompter
//
//  V2 Feature 5 — Voice-Tracked Auto-Scroll.
//
//  Pure-function phonetic key generator. Folds homophones and common ASR
//  near-misses ("their"/"there"/"they're", "knight"/"night",
//  "phone"/"fone", "write"/"right", ...) onto the same code so
//  ScriptAligner can land matches even when the speech recognizer
//  produces a different spelling than the script uses.
//
//  This is a pragmatic Metaphone-flavored primary code — not the full
//  Lawrence Philips Double Metaphone (which is ~200 specific rules and
//  emits two codes per word). Coverage is the subset the design doc
//  cites by name, plus the standard digraph folds (PH→F, TH→0, CH→X,
//  SH→X, CK→K, GH-silent) and the common consonant equivalence pairs
//  (Z→S, Q→K, V→F, B→P, D→T) that catch the most common ASR confusions
//  in noisy environments.
//
//  See V2 Design 03 — Voice Tracking.md §"Algorithm" step 5.
//

import Foundation

public enum PhoneticEncoder {

    /// Encode a single word to a phonetic key. Empty string in → empty
    /// string out. Pure: same input always produces the same output.
    public static func encode(_ raw: String) -> String {
        // Normalize: uppercase, then keep only ASCII letters. Apostrophes,
        // hyphens, whitespace, diacritics — all stripped before rules run.
        let chars: [Character] = raw.uppercased().filter { $0.isASCII && $0.isLetter }
        let n = chars.count
        guard n > 0 else { return "" }

        var output: [Character] = []
        var pos = 0

        // Silent-prefix rules at position 0.
        // GN, KN, PN, WR, PS — drop the first letter so the second leads
        // (handles "knight", "write", "gnome", "pneumatic", "psychology").
        if n >= 2 {
            switch (chars[0], chars[1]) {
            case ("G", "N"), ("K", "N"), ("P", "N"), ("W", "R"), ("P", "S"):
                pos = 1
            default:
                break
            }
        }

        // Append a code char, collapsing immediate duplicates so "letter"
        // and "leter" hash equivalently.
        func emit(_ c: Character) {
            if output.last != c {
                output.append(c)
            }
        }

        let vowels: Set<Character> = ["A", "E", "I", "O", "U", "Y"]

        while pos < n {
            let c = chars[pos]
            let next: Character? = pos + 1 < n ? chars[pos + 1] : nil
            let isFirstEmit = output.isEmpty

            // Vowels (Y treated as vowel here): emit "A" only if this is
            // the very first code character; subsequent vowels drop. Folds
            // "cat"/"cot" and "apple"/"epple".
            if vowels.contains(c) {
                if isFirstEmit {
                    emit("A")
                }
                pos += 1
                continue
            }

            // Two-letter rules. Order matters — match the most specific
            // pair first.
            if let nxt = next {
                switch (c, nxt) {
                case ("P", "H"):
                    emit("F"); pos += 2; continue
                case ("T", "H"):
                    emit("0"); pos += 2; continue
                case ("C", "H"):
                    emit("X"); pos += 2; continue
                case ("S", "H"):
                    emit("X"); pos += 2; continue
                case ("C", "K"):
                    emit("K"); pos += 2; continue
                case ("G", "H"):
                    // GH at start emits K ("ghost"). Elsewhere it's
                    // silent ("right", "knight").
                    if isFirstEmit {
                        emit("K")
                    }
                    pos += 2
                    continue
                default:
                    break
                }
            }

            // Single-letter rules.
            switch c {
            case "B":
                emit("P")
            case "C":
                // Soft C before E/I/Y → S; hard C otherwise → K.
                if let nxt = next, "EIY".contains(nxt) {
                    emit("S")
                } else {
                    emit("K")
                }
            case "D":
                emit("T")
            case "F":
                emit("F")
            case "G":
                // Default fold to K. (A future refinement could split
                // soft-G before E/I/Y to J, but no current test depends
                // on it and the K-fold collides "gone"/"cone" which is
                // acceptable for ASR robustness.)
                emit("K")
            case "H":
                // Silent unless between two vowels: "hello" drops H
                // ("AL"), but "ahead" keeps it ("AHT").
                let prevIsVowel = pos > 0 && vowels.contains(chars[pos - 1])
                let nextIsVowel = next.map { vowels.contains($0) } ?? false
                if prevIsVowel && nextIsVowel {
                    emit("H")
                }
            case "J":
                emit("J")
            case "K":
                emit("K")
            case "L":
                emit("L")
            case "M":
                emit("M")
            case "N":
                emit("N")
            case "P":
                emit("P")
            case "Q":
                emit("K")
            case "R":
                emit("R")
            case "S":
                emit("S")
            case "T":
                emit("T")
            case "V":
                emit("F")
            case "W":
                // W at the very start emits W; elsewhere silent. Folds
                // "kween"/"queen" because the K-then-W collapses to just
                // K via the queen path (Q→K, U vowel drops).
                if pos == 0 {
                    emit("W")
                }
            case "X":
                if pos == 0 {
                    emit("S")
                } else {
                    emit("K")
                    emit("S")
                }
            case "Z":
                emit("S")
            default:
                // Should be unreachable — the input filter strips
                // non-ASCII-letters before this loop runs.
                break
            }

            pos += 1
        }

        return String(output)
    }
}

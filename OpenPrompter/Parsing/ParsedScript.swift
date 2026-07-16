//
//  ParsedScript.swift
//  OpenPrompter
//
//  Structured, spoken-text output of the markdown parsing pipeline.
//  Preserves block type so the prompter can render headings, bullets,
//  and paragraphs with distinct typography. Also exposes a flat
//  `paragraphs` / `bodyText` view for callers that just want the text.
//
//  Inline emphasis (bold / italic / inline-code) is preserved as a list
//  of `InlineRun`s on each text-bearing block so the prompter can render
//  `**bold**` and `*italic*` with the right weight / slant (GitHub #3).
//  The flat `text` / `bodyText` projections stay PLAIN — markers stripped,
//  no styling — because voice tracking, word count, and edit-teleport all
//  depend on a plain string that matches what the parser shipped before.
//

import Foundation

/// One contiguous run of inline text plus its emphasis flags. `bold` and
/// `italic` are independent booleans so `***both***` (Strong wrapping
/// Emphasis) sets both at once. `code` marks an inline code span — the
/// backticks are already gone from `text`; the flag is kept for fidelity
/// and any future distinct styling (today it renders in the body font).
struct InlineRun: Equatable, Hashable, Sendable {
    var text: String
    var bold: Bool
    var italic: Bool
    var code: Bool

    init(text: String, bold: Bool = false, italic: Bool = false, code: Bool = false) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.code = code
    }
}

/// A run of styled inline text plus its flattened plain projection. `plain`
/// is the single source of truth for everything that wants spoken text
/// (voice tracking, word count, `ScriptBlock.text`, block identity); `runs`
/// drives rendering. The two are kept in lockstep at construction time so a
/// caller can never see a `plain` that disagrees with `runs.joined`.
struct StyledText: Equatable, Hashable, Sendable {
    let runs: [InlineRun]
    let plain: String

    /// Styled runs whose join is already known to equal `plain`. Used by the
    /// cleaner after it has reconciled the run cleanup against the
    /// authoritative plain-text cleanup.
    init(runs: [InlineRun], plain: String) {
        self.runs = runs
        self.plain = plain
    }

    /// Styled runs only — derives `plain` by joining them.
    init(runs: [InlineRun]) {
        self.runs = runs
        self.plain = runs.map(\.text).joined()
    }

    /// Unstyled text — a single regular run. The graceful fallback when run
    /// cleanup can't be reconciled with the plain-text cleanup.
    init(plain: String) {
        self.plain = plain
        self.runs = plain.isEmpty ? [] : [InlineRun(text: plain)]
    }

    var isEmpty: Bool { plain.isEmpty }
}

enum ScriptBlock: Equatable, Hashable, Sendable, Identifiable {
    case heading(level: Int, text: String)
    case paragraph(StyledText)
    case bullet(StyledText)
    case numbered(index: Int, text: StyledText)

    var id: String {
        switch self {
        case .heading(let level, let text): return "h\(level)-\(text)"
        case .paragraph(let styled): return "p-\(styled.plain)"
        case .bullet(let styled): return "b-\(styled.plain)"
        case .numbered(let i, let styled): return "n\(i)-\(styled.plain)"
        }
    }

    /// Flattened plain text — markers stripped, no styling. What every spoken-
    /// text consumer (voice tracking, word count, edit-teleport) reads.
    var text: String {
        switch self {
        case .heading(_, let text): return text
        case .paragraph(let styled): return styled.plain
        case .bullet(let styled): return styled.plain
        case .numbered(_, let styled): return styled.plain
        }
    }

    /// True if this block is a markdown heading. Used by remote-driven
    /// section navigation (Feature 7) to find the next/previous H1/H2.
    var isHeading: Bool {
        if case .heading = self { return true }
        return false
    }
}

struct ParsedScript: Equatable, Hashable, Sendable {
    let blocks: [ScriptBlock]

    /// Explicit video-marker cues (V3 headline, H0b), keyed by block index.
    /// A block whose raw markdown carried a `[MARK]` / `[MARK: title]` /
    /// `[[mark]]` cue appears here; the value is the cue's title (`nil` for a
    /// bare `[MARK]`). The cue itself is stripped from the block's DISPLAYED
    /// text — this map is how the recording layer knows which blocks drop a
    /// script marker and what to name it. Headings are NOT listed here; they
    /// mark by virtue of `ScriptBlock.isHeading`. Empty for the common case.
    let markerCues: [Int: String?]

    init(blocks: [ScriptBlock], markerCues: [Int: String?] = [:]) {
        self.blocks = blocks
        self.markerCues = markerCues
    }

    var paragraphs: [String] {
        blocks.map(\.text)
    }

    var bodyText: String {
        paragraphs.joined(separator: "\n\n")
    }

    var isEmpty: Bool {
        blocks.isEmpty
    }

    var wordCount: Int {
        paragraphs.reduce(0) { total, paragraph in
            total + paragraph.split(whereSeparator: \.isWhitespace).count
        }
    }

    static let empty = ParsedScript(blocks: [])
}

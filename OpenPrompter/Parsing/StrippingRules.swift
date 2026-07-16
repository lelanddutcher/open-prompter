//
//  StrippingRules.swift
//  OpenPrompter
//
//  Regex patterns and label lists that drive the markdown stripping pipeline.
//  One StrippingRules instance is a parser configuration; ship `.aggressive`
//  by default with a `.gentle` alternative accessible from Settings in v1.1.
//
//  DISPLAY-TIME ONLY. Everything here removes cruft from the *render copy*
//  the cleaner emits — the `.md` on disk and the in-memory source string are
//  never touched (see `MarkdownCleaner`, which always works on a `var working`
//  copy of the input and returns a fresh `ParsedScript`).
//
//  Stage-direction / camera-cue stripping (V3 sprint item 4) broadens the
//  legacy `visualDirection` bracket set into three cooperating patterns —
//  `stageDirectionBracket`, `stageDirectionParen`, and `stageDirectionCaps`
//  — plus a whole-line classifier `stageDirectionLine`. These fire only when
//  the config's `stripStageDirections` flag is set (aggressive on; gentle
//  off), so the existing gentle mode keeps every cue visible on camera.
//

import Foundation

struct StrippingRules: Sendable {
    let frontmatter: NSRegularExpression
    let aiCallout: NSRegularExpression
    let footnoteDef: NSRegularExpression
    let footnoteMarker: NSRegularExpression
    let tableRow: NSRegularExpression
    let visualDirection: NSRegularExpression
    /// Video-marker cue (V3 headline, H0b script markers). Matches
    /// `[MARK]`, `[MARK: title]`, `[mark]`, and the double-bracket
    /// `[[mark]]` / `[[mark: title]]` forms. Case-insensitive. ALWAYS active
    /// — even in gentle mode — because a marker cue is control metadata, not
    /// readable content: it's hidden from the reader in every mode and routed
    /// to the marker extractor (`markerCue(in:)`) instead. Kept as its own
    /// field (rather than folded into the stage-direction family) so the
    /// gentle / stage-direction toggles never accidentally re-expose it.
    let markerCue: NSRegularExpression
    let hrSplit: String
    let droppedSectionHeading: NSRegularExpression
    let scaffoldLabel: NSRegularExpression

    // MARK: - Stage-direction / camera-cue detection (V3 item 4)

    /// When true, the broadened stage-direction / camera-cue patterns below
    /// are applied on top of `visualDirection`. When false (gentle mode) they
    /// are inert never-match regexes, so cues survive into the reading flow.
    let stripStageDirections: Bool

    /// Inline bracketed cues: `[B-roll: …]`, `[Cut to: …]`, `[SFX: …]`,
    /// `[VO: …]`, `[on screen: …]`, `[graphic: …]`, and the bare
    /// `[wide shot]` / `[close up]` shot families. Broader than
    /// `visualDirection` (which is a curated keyword list) — this matches on
    /// the *shape* of a stage direction (a leading cue keyword, a colon, or a
    /// short bracketed shot phrase) rather than an exhaustive vocabulary.
    let stageDirectionBracket: NSRegularExpression

    /// Inline parentheticals used as performance directions: `(beat)`,
    /// `(pause)`, `(laughs)`, `(to camera)`, `(sotto)`, `(cont'd)` and the
    /// like. Kept deliberately narrow — a general "(anything)" strip would
    /// eat legitimate asides — so it matches a short parenthetical of one to
    /// four words with no sentence-ending punctuation inside.
    let stageDirectionParen: NSRegularExpression

    /// Inline ALL-CAPS shot / transition directions embedded mid-line:
    /// `CUT TO:`, `SMASH CUT TO:`, `FADE IN:`, `DISSOLVE TO:`, `WIDE SHOT`,
    /// `CLOSE ON …`. Screenplay convention writes these in caps; we key off
    /// the caps run plus a known shot/transition head-word so ordinary
    /// emphatic caps ("I said NO") are left alone.
    let stageDirectionCaps: NSRegularExpression

    /// Whole-line classifier: a cleaned block that *is* a stage direction
    /// (e.g. a line that reads only `WIDE SHOT`, `CUT TO: the anchor desk`,
    /// or `(beat)`), so the whole block is dropped rather than emptied to a
    /// stray fragment. Mirrors the role `scaffoldLabel` plays for scaffolding.
    let stageDirectionLine: NSRegularExpression

    static let aggressive: StrippingRules = makeAggressive()
    static let gentle: StrippingRules = makeGentle()

    /// Aggressive stripping WITHOUT the broadened stage-direction / camera-cue
    /// pass (V3 item 4). Same as `.aggressive` for frontmatter / callouts /
    /// footnotes / tables / the legacy `visualDirection` bracket set, but the
    /// four stage-direction patterns are inert so `(beat)`, `CUT TO:`, and
    /// bracket cues that fall outside the legacy vocabulary survive into the
    /// reading flow. Used when the user keeps aggressive stripping on but
    /// turns the stage-direction toggle off.
    static let aggressiveKeepingStageDirections: StrippingRules = makeAggressiveKeepingStageDirections()

    /// Resolve the effective rules from the two independent parsing toggles.
    /// `aggressive == false` short-circuits to gentle (which already keeps all
    /// cues); otherwise `stripStageDirections` picks between the full aggressive
    /// rules and the stage-direction-preserving aggressive variant.
    static func resolved(aggressive: Bool, stripStageDirections: Bool) -> StrippingRules {
        guard aggressive else { return .gentle }
        return stripStageDirections ? .aggressive : .aggressiveKeepingStageDirections
    }

    // MARK: - Constructors

    private static func makeAggressive() -> StrippingRules {
        StrippingRules(
            frontmatter: try! NSRegularExpression(
                pattern: "^---\\s*\\n[\\s\\S]*?\\n---\\s*\\n?",
                options: []
            ),
            aiCallout: try! NSRegularExpression(
                pattern: ">\\s*\\[!ai-generated\\][\\s\\S]*?(?=\\n\\n|\\n---|\\n#|\\Z)",
                options: [.caseInsensitive]
            ),
            footnoteDef: try! NSRegularExpression(
                pattern: "^\\[\\^[^\\]]+\\]:[\\s\\S]*?(?=\\n\\n|\\Z)",
                options: [.anchorsMatchLines]
            ),
            footnoteMarker: try! NSRegularExpression(
                pattern: "\\[\\^[^\\]]+\\]",
                options: []
            ),
            tableRow: try! NSRegularExpression(
                pattern: "(^|\\n)\\|[^\\n]+\\n(\\|[-:\\s|]+\\n)?(\\|[^\\n]+\\n)*",
                options: []
            ),
            visualDirection: try! NSRegularExpression(
                pattern: #"\[\s*(?:insert|b[-\s]?roll|screen record|text on screen|split screen|closing shot|open with|show|cut to|over the shoulder|hand pop|subject flash|intercut|push in|tight on|wide on)[^\]]*\]"#,
                options: [.caseInsensitive]
            ),
            markerCue: makeMarkerCue(),
            hrSplit: "\n---+\n",
            droppedSectionHeading: try! NSRegularExpression(
                pattern: "##\\s*(footnotes|reference images|topic waterfall|sources?|related)",
                options: [.caseInsensitive]
            ),
            scaffoldLabel: try! NSRegularExpression(
                // Match at the start of a line. The label can stand alone
                // ("Template") or be followed by a colon + any content
                // ("Template: Problem → DIY Solution"). Both forms are
                // treated as scaffolding to strip.
                pattern: "^(hook type|pillar|template|version [ab]|footnotes|reference images|topic waterfall|related|sources?)(\\s*:|\\s*$)",
                options: [.caseInsensitive]
            ),
            stripStageDirections: true,
            stageDirectionBracket: makeStageDirectionBracket(),
            stageDirectionParen: makeStageDirectionParen(),
            stageDirectionCaps: makeStageDirectionCaps(),
            stageDirectionLine: makeStageDirectionLine()
        )
    }

    private static func makeGentle() -> StrippingRules {
        // Gentle mode: strip frontmatter and AI callouts only.
        // Keep visual directions AND stage directions (user may want to see
        // [B-roll] / (beat) / CUT TO: cues on camera).
        let aggressive = makeAggressive()
        let never = try! NSRegularExpression(pattern: "(?!)", options: []) // never matches
        return StrippingRules(
            frontmatter: aggressive.frontmatter,
            aiCallout: aggressive.aiCallout,
            footnoteDef: aggressive.footnoteDef,
            footnoteMarker: aggressive.footnoteMarker,
            tableRow: aggressive.tableRow,
            visualDirection: never,
            // Marker cue stays ACTIVE in gentle mode — it's control metadata,
            // never readable content, so it's stripped + extracted regardless.
            markerCue: aggressive.markerCue,
            hrSplit: aggressive.hrSplit,
            droppedSectionHeading: aggressive.droppedSectionHeading,
            scaffoldLabel: aggressive.scaffoldLabel,
            stripStageDirections: false,
            stageDirectionBracket: never,
            stageDirectionParen: never,
            stageDirectionCaps: never,
            stageDirectionLine: never
        )
    }

    private static func makeAggressiveKeepingStageDirections() -> StrippingRules {
        // Full aggressive rules, but the broadened stage-direction pass is
        // disabled (never-match) and the flag is off. The legacy
        // `visualDirection` bracket set still strips, matching pre-V3
        // aggressive behaviour exactly.
        let aggressive = makeAggressive()
        let never = try! NSRegularExpression(pattern: "(?!)", options: [])
        return StrippingRules(
            frontmatter: aggressive.frontmatter,
            aiCallout: aggressive.aiCallout,
            footnoteDef: aggressive.footnoteDef,
            footnoteMarker: aggressive.footnoteMarker,
            tableRow: aggressive.tableRow,
            visualDirection: aggressive.visualDirection,
            markerCue: aggressive.markerCue,
            hrSplit: aggressive.hrSplit,
            droppedSectionHeading: aggressive.droppedSectionHeading,
            scaffoldLabel: aggressive.scaffoldLabel,
            stripStageDirections: false,
            stageDirectionBracket: never,
            stageDirectionParen: never,
            stageDirectionCaps: never,
            stageDirectionLine: never
        )
    }

    // MARK: - Stage-direction pattern builders
    //
    // Hoisted into named factories so the `.gentle`/`.aggressive` constructors
    // read cleanly and so the (verbose) patterns are documented in one place.

    /// Distinctive cue / shot / transition phrases that mark a screenplay
    /// direction. Deliberately excludes bare common words (`show`, `hold`,
    /// `record`, `pause`, `beat`, `super`, `reveal`, `camera`) whose presence
    /// in ordinary prose would cause false drops — those are handled, where
    /// safe, only inside brackets or parentheses. Every entry here is a
    /// multi-word phrase or a domain term unlikely to appear mid-sentence.
    /// Ordered longest-first where prefix-overlap matters (e.g. "smash cut
    /// to" before "cut to").
    private static let cuePhrases =
        "b[-\\s]?roll|screen[-\\s]?record|text on screen|lower third|"
        + "smash cut to|match cut to|jump cut to|hard cut to|cut to|cutaway|"
        + "fade in|fade out|fade to black|fade to|dissolve to|cross[-\\s]?dissolve|"
        + "wipe to|iris in|iris out|"
        + "wide shot|wide on|medium shot|close[-\\s]?up|close on|tight on|"
        + "extreme close[-\\s]?up|two[-\\s]?shot|over[-\\s]?the[-\\s]?shoulder|"
        + "intercut|split screen|establishing shot|"
        + "push in|pull out|pan (?:left|right|up|down)|tilt (?:up|down)|"
        + "zoom in|zoom out|dolly (?:in|out)|"
        + "angle on|new angle|reverse angle|title card"

    /// Short performance-direction words for parentheticals: `(beat)`,
    /// `(pause)`, `(laughs)`, `(to camera)`, `(cont'd)`, `(sotto)`, `(V.O.)`.
    /// The `(` context makes these safe even for the common-word entries — a
    /// writer who parenthesizes `(beat)` means the stage direction.
    private static let parenDirectionWords =
        "beat|pause|pauses|breath|breathe|breathes|laughs?|laughing|chuckles?|"
        + "sighs?|smiles?|smiling|whispers?|whispering|shouts?|shouting|"
        + "aside|to camera|to cam|cont'?d|continued|sotto|"
        + "off[-\\s]?screen|v\\.o\\.|o\\.s\\.|voice[-\\s]?over|"
        + "gestures?|nods?|shrugs?|winks?|points?"

    /// Cue keywords that are safe to strip *inside brackets* even though the
    /// bare word is common in prose — the `[` context disambiguates. Union of
    /// `cuePhrases` with the common single words. Bracket contents this
    /// broad are only ever cues in practice.
    private static let bracketCueWords =
        cuePhrases
        + "|insert|montage|graphic|chyron|sfx|vfx|vo|v\\.o\\.|o\\.s\\.|super|"
        + "on screen|show|reveal|reveal on|hold on|record|beat|pause|camera|"
        + "closing shot|open with|hand pop|subject flash|establishing"

    private static func makeStageDirectionBracket() -> NSRegularExpression {
        // A bracketed cue is a `[...]` whose contents begin with a cue
        // keyword (optionally followed by `:` and detail) OR are a short
        // bracketed shot phrase ending in "shot"/"on"/"up"/"angle". We do NOT
        // strip arbitrary `[...]` — markdown links `[text](url)` and wikilinks
        // `[[...]]` must survive (a following `(` or a second `[`/`]` breaks
        // the match), and only the render copy is affected regardless.
        try! NSRegularExpression(
            pattern:
                "\\[\\s*(?:"
                + "(?:\(bracketCueWords))\\b(?:[^\\]]*)?"                    // keyword [+ detail]
                + "|[A-Za-z][A-Za-z'\\- ]{0,40}?\\s(?:shot|angle|up|on)"     // "... shot" / "... angle"
                + ")\\s*\\]",
            options: [.caseInsensitive]
        )
    }

    private static func makeStageDirectionParen() -> NSRegularExpression {
        // A parenthetical performance direction: `(` + one of the direction
        // words (optionally with a couple of trailing words like "to camera")
        // + `)`. Kept narrow so `(see figure 2)` or `(2020)` are NOT eaten:
        // the first token must be a known direction word, matched whole via
        // the trailing `\b`.
        try! NSRegularExpression(
            pattern:
                "\\(\\s*(?:\(parenDirectionWords))\\b"
                + "(?:[ ,][A-Za-z'\\.]+){0,3}\\s*\\)",
            options: [.caseInsensitive]
        )
    }

    private static func makeStageDirectionCaps() -> NSRegularExpression {
        // Mid-line ALL-CAPS shot / transition directions. Requires a caps run
        // that IS a recognizable multi-word transition or shot phrase, so
        // ordinary shouted caps ("I said NO", "INSERT the key") are not
        // mistaken for a direction. Trailing `\b` prevents chewing the head of
        // a longer caps word; an optional trailing `:` + caps detail run
        // (`CUT TO: THE DESK`) is consumed.
        try! NSRegularExpression(
            pattern:
                "\\b(?:SMASH CUT TO|MATCH CUT TO|JUMP CUT TO|HARD CUT TO|CUT TO|"
                + "FADE IN|FADE OUT|FADE TO BLACK|FADE TO|DISSOLVE TO|CROSS[-\\s]?DISSOLVE|"
                + "WIDE SHOT|WIDE ON|MEDIUM SHOT|CLOSE[-\\s]?UP|CLOSE ON|TIGHT ON|"
                + "EXTREME CLOSE[-\\s]?UP|TWO[-\\s]?SHOT|OVER[-\\s]?THE[-\\s]?SHOULDER|"
                + "ESTABLISHING SHOT|SPLIT SCREEN|"
                + "ANGLE ON|NEW ANGLE|REVERSE ANGLE|PUSH IN|PULL OUT|"
                + "ZOOM IN|ZOOM OUT|PAN (?:LEFT|RIGHT|UP|DOWN)|TILT (?:UP|DOWN))"
                + "\\b(?:\\s*:[ A-Z0-9'\\.,\\-]*)?",   // optional ": DETAIL" in caps
            options: []   // case-sensitive on purpose — only ALL-CAPS runs
        )
    }

    // MARK: - Marker cue (V3 headline, H0b)

    /// Regex for the video-marker cue family: `[MARK]`, `[MARK: title]`,
    /// `[mark]`, `[[mark]]`, `[[mark: title]]`. The optional second `[`/`]`
    /// makes the double-bracket form match; the title after `:` is captured
    /// (group 1) so `markerCue(in:)` can read it. Anchored to the whole
    /// bracket so it strips cleanly from the render copy.
    private static func makeMarkerCue() -> NSRegularExpression {
        try! NSRegularExpression(
            pattern: #"\[\[?\s*mark\b\s*(?::\s*([^\]]*?))?\s*\]?\]"#,
            options: [.caseInsensitive]
        )
    }

    /// Shared marker-cue regex, built once. Used both for stripping the cue
    /// from displayed text and for extracting its optional title.
    static let markerCueRegex: NSRegularExpression = makeMarkerCue()

    /// Extracts the FIRST marker cue in `text`, if any. Returns:
    /// - `nil` — no `[MARK]` cue present.
    /// - `.some(nil)` — a bare `[MARK]` / `[[mark]]` (no title).
    /// - `.some("Intro")` — a `[MARK: Intro]` with a title.
    ///
    /// The double-optional distinguishes "no marker here" from "marker with
    /// no title" so a caller can decide whether the block carries a marker at
    /// all before deciding what to name it.
    static func markerCue(in text: String) -> String?? {
        // Normalize markdown backslash-escapes before brackets. Detection runs
        // on `Markup.format()` output, which re-serializes `[MARK]` and may
        // escape the leading bracket as `\[`; stripping `\[`/`\]` first makes
        // the match robust regardless of the formatter's escaping choices.
        let normalized = text
            .replacingOccurrences(of: "\\[", with: "[")
            .replacingOccurrences(of: "\\]", with: "]")
        let range = NSRange(normalized.startIndex..., in: normalized)
        guard let match = markerCueRegex.firstMatch(in: normalized, options: [], range: range) else {
            return nil            // no cue
        }
        let text = normalized
        // Group 1 is the optional title after the colon.
        guard match.numberOfRanges > 1,
              let titleRange = Range(match.range(at: 1), in: text) else {
            return .some(nil)     // bare [MARK]
        }
        let title = String(text[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return .some(title.isEmpty ? nil : title)
    }

    private static func makeStageDirectionLine() -> NSRegularExpression {
        // Whole cleaned line that IS a stage direction. Anchored at both ends
        // so partial mid-sentence matches don't drop a whole content block.
        // Forms: a distinctive cue phrase line (`WIDE SHOT`, `Cut to: the
        // desk`), a lone parenthetical (`(beat)`), or a lone bracket cue
        // (`[B-roll: …]`). Bare common words are intentionally NOT line
        // triggers — only the bracket/paren forms and distinctive phrases.
        try! NSRegularExpression(
            pattern:
                "^(?:"
                + "(?:\(cuePhrases))\\b(?:\\s*:.*)?"       // "cut to", "wide shot", "cut to: desk"
                + "|\\([^)]*\\)"                            // "(beat)"
                + "|\\[[^\\]]*\\]"                          // "[B-roll: ...]"
                + ")$",
            options: [.caseInsensitive]
        )
    }
}

// MARK: - NSRegularExpression helpers

extension NSRegularExpression {
    /// Returns the input string with all matches replaced by template.
    func removingMatches(in input: String, template: String = "") -> String {
        let range = NSRange(input.startIndex..., in: input)
        return stringByReplacingMatches(in: input, options: [], range: range, withTemplate: template)
    }

    /// Returns true if any match exists in input.
    func hasMatch(in input: String) -> Bool {
        let range = NSRange(input.startIndex..., in: input)
        return firstMatch(in: input, options: [], range: range) != nil
    }
}

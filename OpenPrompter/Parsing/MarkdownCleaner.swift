//
//  MarkdownCleaner.swift
//  OpenPrompter
//
//  Top-level markdown cleaning pipeline. Orchestrates the regex pre-pass,
//  section splitting, swift-markdown AST walk, and visual-direction stripping.
//
//  Pipeline:
//    raw .md
//      -> strip YAML frontmatter (regex)
//      -> strip footnote definitions (regex)
//      -> strip markdown tables (regex)
//      -> split on horizontal rules
//      -> drop sections whose first heading matches scaffold list
//      -> parse each section with swift-markdown
//      -> walk top-level children, classifying each into a ScriptBlock
//      -> per-block regex pass removes visual-direction brackets
//      -> collapse whitespace, emit ParsedScript
//

import Foundation
import Markdown

enum MarkdownCleaner {
    static func clean(
        text: String,
        rules: StrippingRules = .aggressive
    ) -> ParsedScript {
        guard !text.isEmpty else { return .empty }

        // Pre-pass: regex strip.
        // NOTE: AI callouts are handled at the AST level inside ScriptVisitor
        // so multi-paragraph callouts are fully consumed.
        var working = text
        working = rules.frontmatter.removingMatches(in: working)
        working = rules.footnoteDef.removingMatches(in: working)
        working = rules.tableRow.removingMatches(in: working)

        // Split on horizontal rules. `hrSplit` is a regex pattern — normalize any
        // `\n---+\n` run to a literal `\n---\n` sentinel first, then split on that.
        let normalized = normalizeHorizontalRules(working)
        let sections = normalized
            .components(separatedBy: hrSentinel)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { section in
                let head = String(section.prefix(200))
                return !rules.droppedSectionHeading.hasMatch(in: head)
            }

        let pool = sections.isEmpty ? [working] : sections

        var blocks: [ScriptBlock] = []
        // Video-marker cues (V3 headline, H0b): as each top-level node is
        // extracted, we detect a `[MARK]` / `[MARK: title]` / `[[mark]]` cue
        // in the node's markdown source (BEFORE the cleaner strips it) and
        // attach it to the block(s) that node produced, keyed by their final
        // index. `Markup.format()` gives the source without perturbing the
        // visitor, so cue detection is decoupled from the stripping pipeline.
        var markerCues: [Int: String?] = [:]
        for section in pool {
            let document = Document(parsing: section)
            var visitor = ScriptVisitor(rules: rules)
            for child in document.children {
                let cue = StrippingRules.markerCue(in: child.format())
                let startIndex = blocks.count
                blocks.append(contentsOf: extractBlocks(from: child, visitor: &visitor, rules: rules))
                // Attach the cue to the FIRST block the node produced. A node
                // typically yields one block; when it yields several (a list),
                // the cue anchors to the first — the mark fires when that
                // block crosses the eye-line, which is the node's entry point.
                if let cue, blocks.count > startIndex {
                    markerCues[startIndex] = cue
                }
            }
        }

        return ParsedScript(blocks: blocks, markerCues: markerCues)
    }

    // MARK: - Block extraction

    private static func extractBlocks(
        from node: Markup,
        visitor: inout ScriptVisitor,
        rules: StrippingRules
    ) -> [ScriptBlock] {
        switch node {
        case let heading as Heading:
            let raw = visitor.visit(heading)
            guard let cleaned = clean(text: raw, rules: rules) else { return [] }
            let level = max(1, min(heading.level, 6))
            return [.heading(level: level, text: cleaned)]

        case let list as UnorderedList:
            var out: [ScriptBlock] = []
            for item in list.listItems {
                if let styled = styledListItem(item, rules: rules, visitor: &visitor) {
                    out.append(.bullet(styled))
                }
            }
            return out

        case let list as OrderedList:
            var out: [ScriptBlock] = []
            var i = 1
            for item in list.listItems {
                if let styled = styledListItem(item, rules: rules, visitor: &visitor) {
                    out.append(.numbered(index: i, text: styled))
                    i += 1
                }
            }
            return out

        case let blockQuote as BlockQuote:
            let raw = visitor.visit(blockQuote)
            guard let cleaned = clean(text: raw, rules: rules) else { return [] }
            // Multi-paragraph quote → split on blank lines so each becomes its
            // own block. In practice `clean` has already collapsed whitespace
            // (incl. newlines) so this yields a single piece; the styled path
            // applies only to that common single-paragraph case.
            let pieces = cleaned
                .components(separatedBy: "\n\n")
                .compactMap { clean(text: $0, rules: rules) }
            if pieces.count == 1, let only = pieces.first {
                let runs = cleanRuns(InlineStyler.runs(from: blockQuote), rules: rules)
                if runs.map(\.text).joined() == only {
                    // Regular quote — emphasis survives. (A `[!callout]` marker
                    // is stripped from `only` but not from the runs, so those
                    // fail this check and fall through to the plain branch.)
                    return [.paragraph(StyledText(runs: runs, plain: only))]
                }
                return [.paragraph(StyledText(plain: only))]
            }
            return pieces.map { .paragraph(StyledText(plain: $0)) }

        case is CodeBlock, is HTMLBlock, is ThematicBreak, is Table:
            return []

        case let paragraph as Paragraph:
            guard let styled = styledBlock(from: paragraph, rules: rules, visitor: &visitor) else { return [] }
            return [.paragraph(styled)]

        default:
            // Unknown / generic block — fall back to paragraph.
            guard let styled = styledBlock(from: node, rules: rules, visitor: &visitor) else { return [] }
            return [.paragraph(styled)]
        }
    }

    // MARK: - Styled-run extraction

    /// Build a `StyledText` for an inline-bearing block. The plain projection
    /// comes from the existing string pipeline (`clean(text:)`) so it stays
    /// byte-identical to what every spoken-text consumer expects; the styled
    /// runs are reconciled against it. If a cleanup regex spanned an emphasis
    /// boundary (rare — e.g. a bracket cue with inline emphasis inside) the
    /// runs won't match the plain, and we drop styling for that one block so
    /// `bodyText` stays exact.
    private static func styledBlock(
        from container: Markup,
        rules: StrippingRules,
        visitor: inout ScriptVisitor
    ) -> StyledText? {
        let raw = visitor.visit(container)
        guard let plain = clean(text: raw, rules: rules) else { return nil }
        let runs = cleanRuns(InlineStyler.runs(from: container), rules: rules)
        if runs.map(\.text).joined() == plain {
            return StyledText(runs: runs, plain: plain)
        }
        return StyledText(plain: plain)
    }

    /// Styled counterpart to `emitListItem` — joins the item's children with a
    /// single space between them, matching the plain-text join exactly.
    private static func styledListItem(
        _ item: ListItem,
        rules: StrippingRules,
        visitor: inout ScriptVisitor
    ) -> StyledText? {
        let raw = emitListItem(item, visitor: &visitor)
        guard let plain = clean(text: raw, rules: rules) else { return nil }
        var rawRuns: [InlineRun] = []
        var first = true
        for child in item.children {
            if !first { rawRuns.append(InlineRun(text: " ")) }
            first = false
            rawRuns.append(contentsOf: InlineStyler.runs(from: child))
        }
        let runs = cleanRuns(rawRuns, rules: rules)
        if runs.map(\.text).joined() == plain {
            return StyledText(runs: runs, plain: plain)
        }
        return StyledText(plain: plain)
    }

    /// Apply the per-block textual cleanup to styled runs, mirroring the
    /// removal / transform steps in `clean(text:)` (visual-direction brackets,
    /// stage-direction cues, footnote markers, wikilinks) per run, then
    /// normalize whitespace across the run boundaries the same way
    /// `collapseWhitespace` + trim does.
    private static func cleanRuns(_ runs: [InlineRun], rules: StrippingRules) -> [InlineRun] {
        var stage: [InlineRun] = []
        for run in runs {
            var t = rules.markerCue.removingMatches(in: run.text)
            t = rules.visualDirection.removingMatches(in: t)
            t = stripStageDirections(t, rules: rules)
            t = rules.footnoteMarker.removingMatches(in: t)
            t = stripWikilinks(t)
            if !t.isEmpty {
                stage.append(InlineRun(text: t, bold: run.bold, italic: run.italic, code: run.code))
            }
        }
        return normalizeWhitespaceAcrossRuns(stage)
    }

    /// Remove broadened stage-direction / camera-cue spans from a single
    /// string. No-op when the config leaves `stripStageDirections` off
    /// (gentle mode), because those patterns are inert never-match regexes
    /// there. Bracket cues are removed before the caps pass so a bracketed
    /// `[CUT TO: …]` isn't half-consumed by the caps rule first. DISPLAY-TIME
    /// ONLY: operates on a passed-in copy; the source string is never mutated.
    private static func stripStageDirections(_ input: String, rules: StrippingRules) -> String {
        guard rules.stripStageDirections else { return input }
        var t = rules.stageDirectionBracket.removingMatches(in: input)
        t = rules.stageDirectionParen.removingMatches(in: t)
        t = rules.stageDirectionCaps.removingMatches(in: t)
        return t
    }

    /// Collapse every whitespace run to a single space and trim the leading /
    /// trailing space across the whole run sequence — the style-aware
    /// equivalent of `collapseWhitespace(_:).trimmingCharacters(...)`. A
    /// non-whitespace character always emits (preserving run boundaries); a
    /// whitespace character is dropped only when the previously emitted
    /// character was already whitespace.
    private static func normalizeWhitespaceAcrossRuns(_ runs: [InlineRun]) -> [InlineRun] {
        var out: [InlineRun] = []
        var prevWasSpace = true   // seeded true so leading whitespace is trimmed
        for run in runs {
            var built = ""
            for ch in run.text {
                if ch.isWhitespace {
                    if prevWasSpace { continue }
                    built.append(" ")
                    prevWasSpace = true
                } else {
                    built.append(ch)
                    prevWasSpace = false
                }
            }
            if !built.isEmpty {
                out.append(InlineRun(text: built, bold: run.bold, italic: run.italic, code: run.code))
            }
        }
        // Trim a single trailing space left on the last run.
        if var last = out.last, last.text.hasSuffix(" ") {
            last.text.removeLast()
            if last.text.isEmpty {
                out.removeLast()
            } else {
                out[out.count - 1] = last
            }
        }
        return out
    }

    /// Visit a list item's children (typically one Paragraph) and join as one string.
    private static func emitListItem(_ item: ListItem, visitor: inout ScriptVisitor) -> String {
        item.children
            .map { visitor.visit($0) }
            .joined(separator: " ")
    }

    /// Apply per-block whitespace / regex cleanup. Returns nil if nothing
    /// readable survives (too short, only scaffolding, etc).
    private static func clean(text raw: String, rules: StrippingRules) -> String? {
        // Whole-line stage directions (a block that IS "WIDE SHOT" / "CUT TO:
        // desk" / "(beat)") are dropped before any inline surgery, so a lone
        // cue line yields no block instead of a stray fragment. Checked on the
        // collapsed form so leading/trailing whitespace and internal runs
        // don't defeat the anchored match. No-op in gentle mode (never-match).
        if rules.stripStageDirections {
            let collapsed = collapseWhitespace(raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if rules.stageDirectionLine.hasMatch(in: collapsed) { return nil }
        }
        // Marker cue (V3 headline, H0b) is stripped FIRST — before wikilink
        // resolution, which would otherwise turn a `[[mark]]` into the literal
        // word "mark". The cue is control metadata, hidden in every mode; its
        // title (if any) was already captured by `markerCue(in:)` upstream.
        var line = rules.markerCue.removingMatches(in: raw)
        line = rules.visualDirection.removingMatches(in: line)
        line = stripStageDirections(line, rules: rules)
        line = rules.footnoteMarker.removingMatches(in: line)
        line = stripWikilinks(line)
        line = collapseWhitespace(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        guard !rules.scaffoldLabel.hasMatch(in: line) else { return nil }
        // Heading-level extraction sometimes returns a single word (e.g. a drop
        // pattern left only a label). Three-character minimum keeps stragglers out.
        guard line.count >= 3 else { return nil }
        return line
    }

    // MARK: - Helpers

    private static let hrSentinel = "\u{001F}HR\u{001F}"

    private static let hrNormalizeRegex: NSRegularExpression = {
        // One or more dashes on their own line, with optional leading/trailing
        // whitespace (CommonMark allows `---`, `----`, ` --- `, etc.).
        try! NSRegularExpression(
            pattern: "(?m)^[ \\t]*-{3,}[ \\t]*$",
            options: []
        )
    }()

    private static let whitespaceRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "\\s+", options: [])
    }()

    private static let wikilinkRegex: NSRegularExpression = {
        // [[Page|display text]] -> display text
        // [[Page]] -> Page
        try! NSRegularExpression(pattern: "\\[\\[([^\\]|]+)(?:\\|([^\\]]+))?\\]\\]", options: [])
    }()

    /// Replace any line that is purely `-{3,}` (a markdown horizontal rule)
    /// with our section sentinel so `components(separatedBy:)` can split on it.
    private static func normalizeHorizontalRules(_ input: String) -> String {
        let range = NSRange(input.startIndex..., in: input)
        return hrNormalizeRegex.stringByReplacingMatches(
            in: input,
            options: [],
            range: range,
            withTemplate: hrSentinel
        )
    }

    private static func collapseWhitespace(_ input: String) -> String {
        let range = NSRange(input.startIndex..., in: input)
        return whitespaceRegex.stringByReplacingMatches(
            in: input,
            options: [],
            range: range,
            withTemplate: " "
        )
    }

    /// Replace `[[Page|alias]]` with `alias`, `[[Page]]` with `Page`.
    /// Obsidian-specific syntax that swift-markdown doesn't understand.
    static func stripWikilinks(_ input: String) -> String {
        let range = NSRange(input.startIndex..., in: input)
        let matches = wikilinkRegex.matches(in: input, options: [], range: range)
        guard !matches.isEmpty else { return input }

        // Walk matches in reverse so earlier indices stay valid.
        var result = input
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            guard let fullRange = Range(match.range, in: result) else { continue }

            // Prefer the alias (group 2) if present; fall back to the target (group 1).
            let aliasRange = match.range(at: 2)
            let targetRange = match.range(at: 1)
            let replacement: String
            if aliasRange.location != NSNotFound,
               let r = Range(aliasRange, in: result) {
                replacement = String(result[r])
            } else if targetRange.location != NSNotFound,
                      let r = Range(targetRange, in: result) {
                replacement = String(result[r])
            } else {
                replacement = ""
            }
            result.replaceSubrange(fullRange, with: replacement)
        }
        return result
    }
}

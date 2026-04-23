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
        for section in pool {
            let document = Document(parsing: section)
            var visitor = ScriptVisitor(rules: rules)
            for child in document.children {
                blocks.append(contentsOf: extractBlocks(from: child, visitor: &visitor, rules: rules))
            }
        }

        return ParsedScript(blocks: blocks)
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
                let raw = emitListItem(item, visitor: &visitor)
                if let cleaned = clean(text: raw, rules: rules) {
                    out.append(.bullet(cleaned))
                }
            }
            return out

        case let list as OrderedList:
            var out: [ScriptBlock] = []
            var i = 1
            for item in list.listItems {
                let raw = emitListItem(item, visitor: &visitor)
                if let cleaned = clean(text: raw, rules: rules) {
                    out.append(.numbered(index: i, text: cleaned))
                    i += 1
                }
            }
            return out

        case let blockQuote as BlockQuote:
            let raw = visitor.visit(blockQuote)
            guard let cleaned = clean(text: raw, rules: rules) else { return [] }
            // Multi-paragraph quote → split on blank lines so each becomes its own block.
            return cleaned
                .components(separatedBy: "\n\n")
                .compactMap { clean(text: $0, rules: rules) }
                .map { .paragraph($0) }

        case is CodeBlock, is HTMLBlock, is ThematicBreak, is Table:
            return []

        case let paragraph as Paragraph:
            let raw = visitor.visit(paragraph)
            guard let cleaned = clean(text: raw, rules: rules) else { return [] }
            return [.paragraph(cleaned)]

        default:
            // Unknown / generic block — fall back to paragraph.
            let raw = visitor.visit(node)
            guard let cleaned = clean(text: raw, rules: rules) else { return [] }
            return [.paragraph(cleaned)]
        }
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
        var line = rules.visualDirection.removingMatches(in: raw)
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

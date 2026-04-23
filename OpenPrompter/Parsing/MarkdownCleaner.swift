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
//      -> strip ai-generated callouts (regex)
//      -> strip footnote definitions (regex)
//      -> strip markdown tables (regex)
//      -> split on horizontal rules
//      -> drop sections whose first heading matches scaffold list
//      -> parse each section with swift-markdown
//      -> ScriptVisitor emits spoken text
//      -> per-paragraph regex pass removes visual-direction brackets
//      -> collapse whitespace, join paragraphs
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
        // NOTE: We no longer pre-strip AI callouts here — that work moved into
        // ScriptVisitor.visitBlockQuote so we can correctly handle multi-paragraph
        // callouts (the regex stopped at the first blank line inside a callout).
        // Leaving ai-generated blockquotes intact for the AST pass is correct.
        var working = text
        working = rules.frontmatter.removingMatches(in: working)
        working = rules.footnoteDef.removingMatches(in: working)
        working = rules.tableRow.removingMatches(in: working)

        // Split on horizontal rules. Keep sections that aren't footnote/reference/waterfall.
        let sections = working
            .components(separatedBy: rules.hrSplit)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { section in
                let head = String(section.prefix(200))
                return !rules.droppedSectionHeading.hasMatch(in: head)
            }

        let pool = sections.isEmpty ? [working] : sections

        // Per-section: parse AST, walk, emit text.
        var paragraphs: [String] = []
        for section in pool {
            let document = Document(parsing: section)
            var visitor = ScriptVisitor(rules: rules)
            let spoken = visitor.visit(document)

            for rawParagraph in spoken.components(separatedBy: "\n\n") {
                var line = rules.visualDirection.removingMatches(in: rawParagraph)
                line = rules.footnoteMarker.removingMatches(in: line)
                line = stripWikilinks(line)
                line = collapseWhitespace(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                guard !rules.scaffoldLabel.hasMatch(in: line) else { continue }
                guard line.count >= 3 else { continue }
                paragraphs.append(line)
            }
        }

        return ParsedScript(paragraphs: paragraphs)
    }

    /// Compile once, reuse for every call. Was being recompiled per-paragraph.
    private static let whitespaceRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "\\s+", options: [])
    }()

    private static let wikilinkRegex: NSRegularExpression = {
        // [[Page|display text]] -> display text
        // [[Page]] -> Page
        try! NSRegularExpression(pattern: "\\[\\[([^\\]|]+)(?:\\|([^\\]]+))?\\]\\]", options: [])
    }()

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
        return wikilinkRegex.stringByReplacingMatches(
            in: input,
            options: [],
            range: range,
            withTemplate: "$1$2"
        )
    }
}

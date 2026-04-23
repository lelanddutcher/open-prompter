//
//  ScriptVisitor.swift
//  OpenPrompter
//
//  MarkupVisitor subclass that walks the swift-markdown AST and emits
//  spoken-text strings. Skips scaffolding headings, tables, code blocks,
//  HTML blocks, and inline footnote refs while preserving paragraph flow.
//

import Foundation
import Markdown

struct ScriptVisitor: MarkupVisitor {
    typealias Result = String

    let rules: StrippingRules

    mutating func defaultVisit(_ markup: Markup) -> String {
        markup.children
            .map { visit($0) }
            .joined()
    }

    // MARK: - Block-level

    mutating func visitDocument(_ document: Document) -> String {
        document.children
            .map { visit($0) }
            .joined(separator: "\n\n")
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        let plain = heading.plainText.trimmingCharacters(in: .whitespaces)
        if rules.scaffoldLabel.hasMatch(in: plain) { return "" }
        if rules.droppedSectionHeading.hasMatch(in: plain) { return "" }
        // Return heading text as a plain line (no # markers, no emphasis).
        return plain
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        paragraph.children
            .map { visit($0) }
            .joined()
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        // Obsidian callouts encode as blockquotes whose first line is `[!kind]`.
        // Drop AI-generated callouts specifically. Other callout kinds (note,
        // warning, tip, info, quote, etc.) are preserved as spoken content —
        // a plain `> quote` from the writer is real content, not cruft.
        let plain = blockQuote.plainText.trimmingCharacters(in: .whitespaces)
        if plain.lowercased().hasPrefix("[!ai-generated]") {
            return ""
        }
        // Strip the `[!kind]` marker on other callouts but keep their text.
        let withoutMarker = stripCalloutMarker(plain)
        return withoutMarker
    }

    private func stripCalloutMarker(_ input: String) -> String {
        // Remove leading `[!anything]` at start of first line.
        let pattern = try! NSRegularExpression(pattern: "^\\[![^\\]]+\\]\\s*", options: [])
        return pattern.removingMatches(in: input)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        // Code is never spoken.
        return ""
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        return ""
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        return ""
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        listItem.children
            .map { visit($0) }
            .joined()
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
        orderedList.children
            .map { visit($0) }
            .joined(separator: " ")
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
        unorderedList.children
            .map { visit($0) }
            .joined(separator: " ")
    }

    mutating func visitTable(_ table: Table) -> String {
        // Tables in Leland's scripts are always reference material (footnotes,
        // image sources). Skip entirely.
        return ""
    }

    // MARK: - Inline

    mutating func visitText(_ text: Text) -> String {
        text.string
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        emphasis.children.map { visit($0) }.joined()
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        strong.children.map { visit($0) }.joined()
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        // Code spans become plain text for delivery.
        inlineCode.code
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        " "
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        " "
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        ""
    }

    mutating func visitLink(_ link: Link) -> String {
        // Emit link text only — drop the URL.
        link.children.map { visit($0) }.joined()
    }

    mutating func visitImage(_ image: Image) -> String {
        // Images are never spoken.
        ""
    }
}

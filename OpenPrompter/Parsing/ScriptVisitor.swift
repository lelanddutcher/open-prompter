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
        let plain = Self.plainText(of: heading).trimmingCharacters(in: CharacterSet.whitespaces)
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
        let plain = Self.plainText(of: blockQuote).trimmingCharacters(in: CharacterSet.whitespaces)
        if plain.lowercased().hasPrefix("[!ai-generated]") {
            return ""
        }
        // For non-AI callouts, re-emit children as spoken text so paragraph
        // structure inside the blockquote is preserved. Strip the `[!kind]`
        // marker if present on the first line.
        var spoken = defaultVisit(blockQuote)
        spoken = stripCalloutMarker(spoken)
        return spoken
    }

    private func stripCalloutMarker(_ input: String) -> String {
        // Remove leading `[!anything]` at start of first line.
        Self.calloutMarker.removingMatches(in: input)
    }

    // Hoisted so we don't rebuild the regex on every blockquote visit in a
    // large document. Same pattern, evaluated once at type-load time.
    private static let calloutMarker: NSRegularExpression = {
        try! NSRegularExpression(pattern: "^\\[![^\\]]+\\]\\s*", options: [])
    }()

    /// Walk a Markup node's descendants and extract the plain text content,
    /// flattening Text / Emphasis / Strong / InlineCode and dropping everything
    /// else. swift-markdown 0.7.x doesn't expose a uniform `plainText` on
    /// every Markup subtype, so this is our own helper.
    private static func plainText(of markup: any Markup) -> String {
        var pieces: [String] = []
        for child in markup.children {
            if let text = child as? Text {
                pieces.append(text.string)
            } else if let code = child as? InlineCode {
                pieces.append(code.code)
            } else if let linebreak = child as? LineBreak {
                _ = linebreak
                pieces.append(" ")
            } else if let softbreak = child as? SoftBreak {
                _ = softbreak
                pieces.append(" ")
            } else {
                pieces.append(plainText(of: child))
            }
        }
        return pieces.joined()
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

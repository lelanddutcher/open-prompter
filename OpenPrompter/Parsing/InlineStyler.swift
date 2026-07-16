//
//  InlineStyler.swift
//  OpenPrompter
//
//  Walks the inline children of a swift-markdown block node into a flat list
//  of `InlineRun`s, carrying bold / italic / inline-code flags down through
//  nested Strong / Emphasis spans. This is the styled counterpart to
//  `ScriptVisitor`'s plain-text inline flattening — the two MUST agree on
//  which nodes contribute text and what that text is, or the styled runs and
//  the plain projection will drift. Keep the two in sync: Text, InlineCode
//  (as its `.code`), LineBreak / SoftBreak (as a space), Emphasis, Strong,
//  and Link (text only) contribute; Image and InlineHTML are dropped.
//

import Foundation
import Markdown

enum InlineStyler {
    /// Flatten a block node's inline descendants into styled runs. Pass a
    /// Paragraph, Heading, or any container whose `children` are inline.
    static func runs(from container: Markup) -> [InlineRun] {
        var acc: [InlineRun] = []
        append(children: container, bold: false, italic: false, into: &acc)
        return acc
    }

    private static func append(
        children container: Markup,
        bold: Bool,
        italic: Bool,
        into acc: inout [InlineRun]
    ) {
        for child in container.children {
            switch child {
            case let text as Text:
                acc.append(InlineRun(text: text.string, bold: bold, italic: italic))

            case let code as InlineCode:
                // Code spans become plain text for delivery — same string the
                // visitor emits — but we remember they were code.
                acc.append(InlineRun(text: code.code, bold: bold, italic: italic, code: true))

            case is LineBreak, is SoftBreak:
                acc.append(InlineRun(text: " ", bold: bold, italic: italic))

            case let strong as Strong:
                append(children: strong, bold: true, italic: italic, into: &acc)

            case let emphasis as Emphasis:
                append(children: emphasis, bold: bold, italic: true, into: &acc)

            case let link as Link:
                // Emit link text only — drop the URL, matching the visitor.
                append(children: link, bold: bold, italic: italic, into: &acc)

            case is Image, is InlineHTML:
                // Never spoken / never shown — matches the visitor.
                continue

            default:
                // Unknown inline container — recurse so nested text survives.
                append(children: child, bold: bold, italic: italic, into: &acc)
            }
        }
    }
}

//
//  ParsedScript.swift
//  OpenPrompter
//
//  Structured, spoken-text output of the markdown parsing pipeline.
//  Preserves block type so the prompter can render headings, bullets,
//  and paragraphs with distinct typography. Also exposes a flat
//  `paragraphs` / `bodyText` view for callers that just want the text.
//

import Foundation

enum ScriptBlock: Equatable, Hashable, Sendable, Identifiable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case numbered(index: Int, text: String)

    var id: String {
        switch self {
        case .heading(let level, let text): return "h\(level)-\(text)"
        case .paragraph(let text): return "p-\(text)"
        case .bullet(let text): return "b-\(text)"
        case .numbered(let i, let text): return "n\(i)-\(text)"
        }
    }

    var text: String {
        switch self {
        case .heading(_, let text): return text
        case .paragraph(let text): return text
        case .bullet(let text): return text
        case .numbered(_, let text): return text
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

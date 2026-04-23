//
//  ParsedScript.swift
//  OpenPrompter
//
//  The cleaned, spoken-text output of the markdown parsing pipeline.
//  Value type. Hashable so SwiftUI views can use it as an id.
//

import Foundation

struct ParsedScript: Equatable, Hashable, Sendable {
    let paragraphs: [String]

    var bodyText: String {
        paragraphs.joined(separator: "\n\n")
    }

    var isEmpty: Bool {
        paragraphs.isEmpty
    }

    var wordCount: Int {
        paragraphs.reduce(0) { total, paragraph in
            total + paragraph.split(whereSeparator: \.isWhitespace).count
        }
    }

    static let empty = ParsedScript(paragraphs: [])
}

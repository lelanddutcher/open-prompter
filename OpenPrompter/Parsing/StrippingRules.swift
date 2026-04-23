//
//  StrippingRules.swift
//  OpenPrompter
//
//  Regex patterns and label lists that drive the markdown stripping pipeline.
//  One StrippingRules instance is a parser configuration; ship `.aggressive`
//  by default with a `.gentle` alternative accessible from Settings in v1.1.
//

import Foundation

struct StrippingRules: Sendable {
    let frontmatter: NSRegularExpression
    let aiCallout: NSRegularExpression
    let footnoteDef: NSRegularExpression
    let footnoteMarker: NSRegularExpression
    let tableRow: NSRegularExpression
    let visualDirection: NSRegularExpression
    let hrSplit: String
    let droppedSectionHeading: NSRegularExpression
    let scaffoldLabel: NSRegularExpression

    static let aggressive: StrippingRules = makeAggressive()
    static let gentle: StrippingRules = makeGentle()

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
            hrSplit: "\n---+\n",
            droppedSectionHeading: try! NSRegularExpression(
                pattern: "##\\s*(footnotes|reference images|topic waterfall|sources?|related)",
                options: [.caseInsensitive]
            ),
            scaffoldLabel: try! NSRegularExpression(
                pattern: "^(hook type|pillar|template|version [ab]|footnotes|reference images|topic waterfall|related|sources?)\\s*:?\\s*$",
                options: [.caseInsensitive]
            )
        )
    }

    private static func makeGentle() -> StrippingRules {
        // Gentle mode: strip frontmatter and AI callouts only.
        // Keep visual directions (user may want to see [B-roll] cues on camera).
        let aggressive = makeAggressive()
        return StrippingRules(
            frontmatter: aggressive.frontmatter,
            aiCallout: aggressive.aiCallout,
            footnoteDef: aggressive.footnoteDef,
            footnoteMarker: aggressive.footnoteMarker,
            tableRow: aggressive.tableRow,
            visualDirection: try! NSRegularExpression(pattern: "(?!)", options: []), // never matches
            hrSplit: aggressive.hrSplit,
            droppedSectionHeading: aggressive.droppedSectionHeading,
            scaffoldLabel: aggressive.scaffoldLabel
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

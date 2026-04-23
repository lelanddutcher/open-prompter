//
//  PrompterFont.swift
//  OpenPrompter
//
//  Curated list of teleprompter body fonts. The brand monospace still
//  dominates chrome (logos, pills, chips, controls, and script headings)
//  — this enum only governs how the *script body* renders. Choices were
//  picked for reading-at-distance legibility and cover a small, opinionated
//  range: two purpose-built accessibility faces (Atkinson Hyperlegible,
//  Lexend), two iOS system workhorses (System Sans / SF Pro, Verdana), a
//  serif option (Apple's New York), and the brand monospace itself so the
//  original look is still available.
//
//  Bundled TTFs live in `OpenPrompter/Resources/Fonts` and are listed in
//  `UIAppFonts` via `project.yml`. System faces use `Font.system(...)` so
//  they require no bundling.
//

import SwiftUI

enum PrompterFont: String, CaseIterable, Identifiable {
    /// Atkinson Hyperlegible — Braille Institute, designed specifically for
    /// low-vision readers. Bundled.
    case atkinsonHyperlegible = "atkinsonHyperlegible"
    /// Lexend — designed with educational therapist Bonnie Shaver-Troup to
    /// improve reading proficiency via expanded character spacing. Bundled.
    case lexend = "lexend"
    /// System Sans (SF Pro on iOS). Apple's default text face — highly
    /// tuned for on-screen rendering and already familiar to every user.
    case systemSans = "systemSans"
    /// Verdana — Matthew Carter's screen-first sans from 1996. Generous
    /// apertures and wide counters; long a broadcast-caption favourite.
    /// Ships with iOS.
    case verdana = "verdana"
    /// New York — Apple's modern serif, designed for readability in long
    /// blocks of text. Ships with iOS.
    case newYorkSerif = "newYorkSerif"
    /// Brand monospace (SF Mono via `.monospaced`). The original look —
    /// keeps Open Prompter's JetBrains-Mono-esque identity on the body
    /// copy for users who prefer it.
    case brandMono = "brandMono"

    // MARK: - Identity

    var id: String { rawValue }

    /// What the user sees in the Settings picker.
    var displayName: String {
        switch self {
        case .atkinsonHyperlegible: return "Atkinson Hyperlegible"
        case .lexend:               return "Lexend"
        case .systemSans:           return "System Sans"
        case .verdana:              return "Verdana"
        case .newYorkSerif:         return "New York (Serif)"
        case .brandMono:            return "Brand Mono"
        }
    }

    /// One-line note shown beneath the picker. Plain language — no
    /// marketing, just the design intent so the user can pick wisely.
    var designerNote: String? {
        switch self {
        case .atkinsonHyperlegible:
            return "Braille Institute. Engineered for low-vision readers — highly differentiated letterforms."
        case .lexend:
            return "Designed with reading specialists to aid reading proficiency via expanded character spacing."
        case .systemSans:
            return "Apple's default text face, tuned for iOS rendering."
        case .verdana:
            return "Matthew Carter's screen-first sans — wide apertures, a broadcast favourite."
        case .newYorkSerif:
            return "Apple's modern serif. A calmer option for longer reading."
        case .brandMono:
            return "The original Open Prompter look. Monospaced, even rhythm, steady pacing."
        }
    }

    /// Indicates whether this case maps to a bundled TTF. Useful for
    /// diagnostics / "did the font actually register?" checks.
    var isBundled: Bool {
        switch self {
        case .atkinsonHyperlegible, .lexend: return true
        default: return false
        }
    }

    // MARK: - Font resolution

    /// Returns the SwiftUI `Font` to apply to prompter body text at the
    /// requested size. Bundled faces fall back to `Font.system(size:)` if
    /// the custom font failed to register — defensive, never nil.
    func swiftUIFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch self {
        case .atkinsonHyperlegible:
            return customOrSystem(
                postScriptName: weight == .bold ? "AtkinsonHyperlegible-Bold" : "AtkinsonHyperlegible-Regular",
                size: size,
                weight: weight,
                design: .default
            )
        case .lexend:
            return customOrSystem(
                postScriptName: weight == .bold ? "Lexend-Bold" : "Lexend-Regular",
                size: size,
                weight: weight,
                design: .default
            )
        case .systemSans:
            return .system(size: size, weight: weight, design: .default)
        case .verdana:
            // Verdana is pre-installed on iOS. If for some reason it's not
            // present, SwiftUI falls back to the system sans automatically.
            return .custom("Verdana", size: size).weight(weight)
        case .newYorkSerif:
            return .system(size: size, weight: weight, design: .serif)
        case .brandMono:
            return .system(size: size, weight: weight, design: .monospaced)
        }
    }

    /// Build a `Font.custom` for a bundled face. If UIKit reports that
    /// the PostScript name hasn't been registered (e.g. the TTF didn't
    /// ship in the bundle), return the matching system font instead so
    /// the prompter never renders blank. Safe to call on main thread —
    /// `UIFont(name:size:)` is cheap.
    private func customOrSystem(
        postScriptName: String,
        size: CGFloat,
        weight: Font.Weight,
        design: Font.Design
    ) -> Font {
        #if canImport(UIKit)
        if UIFont(name: postScriptName, size: size) != nil {
            return .custom(postScriptName, size: size)
        }
        #endif
        return .system(size: size, weight: weight, design: design)
    }

    // MARK: - Defaults

    /// The out-of-the-box selection. Atkinson Hyperlegible because it
    /// was purpose-built for readability at a distance — exactly the
    /// teleprompter use case.
    static let `default`: PrompterFont = .atkinsonHyperlegible
}

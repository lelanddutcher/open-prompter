//
//  Theme.swift
//  OpenPrompter
//
//  Design-language tokens for the app. Mirrors the tokens documented in
//  design-language.md so the iOS build stays in lock-step with marketing,
//  README, and future Mac surfaces. Two font families: system monospace
//  (standing in for JetBrains Mono across chrome, UI labels, script, and
//  wordmark) and system sans (standing in for Inter across body copy).
//

import SwiftUI

enum Theme {
    // MARK: - Color tokens (from design-language.md §2)

    /// `#0A0A0B` — Prompter Black. The only true backdrop.
    static let bg = Color(red: 0x0A / 255, green: 0x0A / 255, blue: 0x0B / 255)
    /// `#131316` — Rig Gray. Cards, elevated surfaces.
    static let surface = Color(red: 0x13 / 255, green: 0x13 / 255, blue: 0x16 / 255)
    /// `#1D1D22` — Mount Gray. Dividers, inactive pills, input bg.
    static let surface2 = Color(red: 0x1D / 255, green: 0x1D / 255, blue: 0x22 / 255)
    /// `#26262C` — Default 1px hairline border.
    static let border = Color(red: 0x26 / 255, green: 0x26 / 255, blue: 0x2C / 255)

    /// `#F4F4F2` — Paper. Primary text. Warm off-white.
    static let fg = Color(red: 0xF4 / 255, green: 0xF4 / 255, blue: 0xF2 / 255)
    /// `#B5B5B0` — Muted Paper. Secondary text.
    static let muted = Color(red: 0xB5 / 255, green: 0xB5 / 255, blue: 0xB0 / 255)
    /// `#6A6A65` — Ghost. Placeholders, disabled, tertiary labels.
    static let ghost = Color(red: 0x6A / 255, green: 0x6A / 255, blue: 0x65 / 255)

    /// `#3FEE7A` — Open Green. Primary accent. Live, CTA, success.
    static let green = Color(red: 0x3F / 255, green: 0xEE / 255, blue: 0x7A / 255)
    /// `#7BFFAA` — Open Green Light. Hover / focus.
    static let greenLight = Color(red: 0x7B / 255, green: 0xFF / 255, blue: 0xAA / 255)
    /// `#22B256` — Open Green Deep. Long runs of body green.
    static let greenDeep = Color(red: 0x22 / 255, green: 0xB2 / 255, blue: 0x56 / 255)

    /// `#FF3B4A` — Mirror Red. Mirror-mode state only.
    static let red = Color(red: 0xFF / 255, green: 0x3B / 255, blue: 0x4A / 255)
    /// `#FFB84C` — Amber. Warning / syncing.
    static let amber = Color(red: 0xFF / 255, green: 0xB8 / 255, blue: 0x4C / 255)

    // MARK: - Backward-compat aliases
    //
    // Earlier code in the app used `dim`, `alert`, `safe`, `accent`, `controlBg`,
    // `controlBorder` as token names. Keep them as thin aliases so the view
    // diff stays small — new code should prefer the named tokens above.

    static let dim = muted
    static let alert = red
    static let safe = green
    static let accent = green
    static let controlBg = surface
    static let controlBorder = border

    // MARK: - Shape tokens (from design-language.md §5)

    /// 40pt — smallest allowable hit target.
    static let hitMin: CGFloat = 40
    /// 44pt — primary thumb-driven targets on iOS.
    static let hitPrimary: CGFloat = 44
    /// 52pt — primary CTA buttons.
    static let hitCTA: CGFloat = 52
    static let minButtonSize: CGFloat = 52
    /// 6–8pt for small controls.
    static let radiusSm: CGFloat = 8
    /// 10–14pt for cards.
    static let radiusMd: CGFloat = 12
    static let cornerRadius: CGFloat = 12
    /// 999 for pills / chips / CTAs.
    static let pillRadius: CGFloat = 999
    static let controlGap: CGFloat = 8

    // MARK: - Spacing tokens (from design-language.md §4)

    static let s4: CGFloat = 4
    static let s8: CGFloat = 8
    static let s12: CGFloat = 12
    static let s16: CGFloat = 16
    static let s20: CGFloat = 20
    static let s24: CGFloat = 24
    static let s32: CGFloat = 32
    static let s48: CGFloat = 48

    // MARK: - Type scale (from design-language.md §3)
    //
    // Roles map onto SwiftUI `Font` values. We use the system monospace
    // face ("SF Mono") as a stand-in for JetBrains Mono and the default
    // sans for Inter. If we later bundle the licensed fonts we only need
    // to change these accessors.

    enum TypeRole {
        case heroH1
        case sectionH2
        case cardH3
        case body
        case lede
        case uiLabel
        case uiLabelTiny
        case script
        case caption
    }

    static func font(_ role: TypeRole) -> Font {
        switch role {
        case .heroH1:     return .system(size: 68, weight: .heavy, design: .monospaced)
        case .sectionH2:  return .system(size: 28, weight: .heavy, design: .monospaced)
        case .cardH3:     return .system(size: 20, weight: .semibold, design: .monospaced)
        case .body:       return .system(size: 16, weight: .regular)
        case .lede:       return .system(size: 18, weight: .regular)
        case .uiLabel:    return .system(size: 12, weight: .semibold, design: .monospaced)
        case .uiLabelTiny:return .system(size: 10, weight: .semibold, design: .monospaced)
        case .script:     return .system(size: 22, weight: .regular, design: .monospaced)
        case .caption:    return .system(size: 11, weight: .regular, design: .monospaced)
        }
    }

    /// Tracking (letter-spacing) per role. SwiftUI `.tracking()` uses points.
    static func tracking(_ role: TypeRole) -> CGFloat {
        switch role {
        case .heroH1:     return -2.4   // -0.035em at 68pt
        case .sectionH2:  return -0.84  // -0.03em at 28pt
        case .cardH3:     return -0.3   // -0.015em at 20pt
        case .body, .lede: return 0
        case .uiLabel, .uiLabelTiny, .caption:
                          return 1.2    // +0.1em on small caps labels
        case .script:     return -0.22
        }
    }

    // MARK: - Legacy size aliases used by existing views

    static let sizeLabelSm: CGFloat = 11
    static let sizePill: CGFloat = 11
    static let sizeBody: CGFloat = 14
    static let sizeButton: CGFloat = 16
    static let sizeTitle: CGFloat = 22
    static let sizeDisplay: CGFloat = 32

    // MARK: - Durations

    static let mirrorAnim: Double = 0.14
    static let focusAnim: Double = 0.25
    static let pillTap: Double = 0.08
    /// 120–150ms per spec.
    static let hoverAnim: Double = 0.14
    /// 80ms button press.
    static let pressAnim: Double = 0.08
}

// MARK: - Convenience view modifier for applying a type role.

extension View {
    func typeRole(_ role: Theme.TypeRole) -> some View {
        self.font(Theme.font(role))
            .tracking(Theme.tracking(role))
    }
}

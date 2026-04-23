//
//  Wordmark.swift
//  OpenPrompter
//
//  The `[open] prompter` wordmark and the 22×22 brand glyph, per
//  design-language.md §7.1 and §10. Rendered programmatically so the
//  app bundle stays font-and-SVG-free; if we later bundle JetBrains
//  Mono the glyph and wordmark inherit the new face automatically.
//

import SwiftUI

/// 22×22 rounded-square with a green border and a green `▸` play triangle.
struct BrandGlyph: View {
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .stroke(Theme.green, lineWidth: max(1, size / 14))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(Theme.green)
                    .offset(x: size * 0.04) // optical centering
            )
    }
}

/// The full `[open] prompter` wordmark. `open` is bracketed in Open Green;
/// both words lowercase, monospaced. Brand glyph sits to the left.
struct Wordmark: View {
    /// Character height in points; brackets + text scale with this.
    var size: CGFloat = 18
    /// Whether the brand glyph appears to the left of the text.
    var showGlyph: Bool = true

    var body: some View {
        HStack(spacing: size * 0.45) {
            if showGlyph {
                BrandGlyph(size: size * 1.2)
            }
            (
                Text("[").foregroundStyle(Theme.green) +
                Text("open").foregroundStyle(Theme.fg) +
                Text("]").foregroundStyle(Theme.green) +
                Text(" prompter").foregroundStyle(Theme.fg)
            )
            .font(.system(size: size, weight: .heavy, design: .monospaced))
            .tracking(-size * 0.02)
        }
    }
}

#Preview {
    VStack(spacing: 24) {
        BrandGlyph()
        BrandGlyph(size: 44)
        Wordmark()
        Wordmark(size: 32)
        Wordmark(size: 24, showGlyph: false)
    }
    .padding()
    .background(Theme.bg)
}

//
//  ReadingProgressBar.swift
//  OpenPrompter
//
//  A thin vertical read-position indicator down the LEFT edge of the
//  prompter — a page-scrollbar feel in the classic OpenPrompter green.
//  The green fill grows from the top as you read: about half when you're
//  mid-script, near the bottom as you approach the end. Purely
//  informational, non-interactive, and mounted OUTSIDE the mirrored text
//  layer so it never flips.
//

import SwiftUI

struct ReadingProgressBar: View {
    /// Read position through the script, 0 (top) … 1 (end).
    let fraction: CGFloat

    /// Hairline. Halved from 3 pt in 3.1 — at 3 pt the bar read as chrome
    /// competing with the script; 1.5 pt is a glanceable hint and nothing
    /// more. Whether it shows at all is `Prefs.showReadingProgressBar`,
    /// gated at the mount site in `TeleprompterView`.
    private let barWidth: CGFloat = 1.5

    private var clamped: CGFloat { min(max(fraction, 0), 1) }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .top) {
                // Subtle full-height track.
                Capsule()
                    .fill(Theme.green.opacity(0.14))
                    .frame(width: barWidth, height: h)
                // Green fill to the current read position.
                Capsule()
                    .fill(Theme.green)
                    .frame(width: barWidth, height: max(0, h * clamped))
            }
        }
        .frame(width: barWidth)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

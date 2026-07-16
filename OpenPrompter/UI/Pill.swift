//
//  Pill.swift
//  OpenPrompter
//
//  The "ghost pill" pattern from design-language.md §7.3. Mono label,
//  uppercase, tight tracking, Surface bg + hairline border. Alert variant
//  swaps in Mirror Red per §2.2 — the only place red may appear.
//

import SwiftUI

struct Pill: View {
    let text: String
    var alert: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(0.6)
            .foregroundStyle(alert ? Color.white : Theme.muted)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassSurface(in: Capsule(), tint: alert ? Theme.red : nil)
    }
}

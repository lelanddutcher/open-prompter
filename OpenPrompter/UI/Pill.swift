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
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(alert ? Color.white : Theme.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(alert ? Theme.red : Theme.surface)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(alert ? Theme.red : Theme.border, lineWidth: 1))
    }
}

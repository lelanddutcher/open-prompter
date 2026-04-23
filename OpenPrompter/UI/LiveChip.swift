//
//  LiveChip.swift
//  OpenPrompter
//
//  The "live chip" pattern from design-language.md §7.3 — a pill with a
//  colored status dot (+ glow) and a monospaced label. Used in the top bar
//  for sync / reload status and as a template for any future status pill.
//

import SwiftUI

struct LiveChip: View {
    enum Status {
        case live       // green — synced, up to date
        case syncing    // amber — pulling a change
        case stale      // ghost — no connection / unknown
    }

    let status: Status
    let label: String
    var pulse: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .shadow(color: dotColor.opacity(0.85), radius: pulse ? 4 : 2)
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
    }

    private var dotColor: Color {
        switch status {
        case .live:    return Theme.green
        case .syncing: return Theme.amber
        case .stale:   return Theme.ghost
        }
    }
}

#Preview {
    VStack(spacing: 10) {
        LiveChip(status: .live, label: "SYNCED · 2m AGO")
        LiveChip(status: .syncing, label: "SYNCING…", pulse: true)
        LiveChip(status: .stale, label: "OFFLINE")
    }
    .padding()
    .background(Theme.bg)
}

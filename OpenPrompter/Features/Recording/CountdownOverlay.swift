//
//  CountdownOverlay.swift
//  OpenPrompter
//
//  3-2-1 pre-roll overlay. Covers the prompter while
//  `RecordingState.phase == .countdown(remaining:)`. Large, centered,
//  monospaced numerals. Each tick scales down briefly; reduce-motion cuts
//  cleanly between numbers.
//

import SwiftUI

struct CountdownOverlay: View {
    @Bindable var state: RecordingState
    /// Optional cancel handler — tap-anywhere on the overlay during the
    /// countdown returns the chip to idle. The parent decides whether to
    /// route this through the session or to suppress it.
    var onCancel: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        if case .countdown(let remaining) = state.phase {
            ZStack {
                // Dim the prompter slightly so the numeral pops without the
                // text becoming illegible — we still want the user to see
                // where they're starting.
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { onCancel?() }
                    .accessibilityHidden(true)

                Text("\(remaining)")
                    .font(.system(size: 220, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 14, x: 0, y: 6)
                    .id(remaining) // forces transition between digits
                    .transition(reduceMotion ? .identity : .scale.combined(with: .opacity))
                    .accessibilityLabel("\(remaining) seconds")
            }
            .animation(
                reduceMotion ? .linear(duration: 0) : .spring(response: 0.32, dampingFraction: 0.78),
                value: remaining
            )
        }
    }
}

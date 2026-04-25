//
//  TallyLightOverlay.swift
//  OpenPrompter
//
//  4pt-wide red strip along all four screen edges that pulses while the
//  prompter is recording. Per V2 Design 01 §"Tally-light border indicator":
//
//  - Color: pure red `#FF1F1F`. Distinct from `Theme.red` (Mirror Red,
//    `#FF3B4A`) so the two reds don't compete in the user's peripheral
//    vision when both mirror and recording are on.
//  - Animation: 2-second sine pulse on opacity, 60% → 100% → 60%.
//  - Reduce Motion: solid 100% opacity, no pulse.
//  - Z-order: above all UI — placed last in the prompter root ZStack so
//    nothing else can occlude it.
//
//  This ships in Feature 1 even though recording itself is Feature 2; the
//  Labs settings adds a debug toggle to flip it on for design validation
//  until Feature 2 wires the real `RecordingState.isRecording` flow.
//

import SwiftUI

struct TallyLightOverlay: View {
    /// Drives the pulse. When false, the overlay renders nothing — the
    /// prompter is not recording.
    let isActive: Bool
    /// Border thickness in points. Default 4pt per spec; left tunable so
    /// dogfooding can land on 3 or 5 if 4 reads wrong against ProMotion.
    var thickness: CGFloat = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    /// Pulse phase 0…1 driven by `TimelineView`. Used to interpolate opacity
    /// 60% → 100% on a 2-second sine. We use a `TimelineView` (not
    /// `withAnimation`) so the pulse stays buttery even when the prompter
    /// scroll is active under it.
    private let pulsePeriod: TimeInterval = 2.0

    /// Pure-red tally color, intentionally separate from `Theme.red`
    /// (Mirror Red `#FF3B4A`). `#FF1F1F` reads as a stronger primary red
    /// in peripheral vision and is far enough from the brand red that the
    /// user can distinguish a recording state from a mirror state at a glance.
    private static let tallyRed = Color(red: 0xFF / 255, green: 0x1F / 255, blue: 0x1F / 255)

    var body: some View {
        if isActive {
            // Reduce-Motion: solid frame, no pulse. Otherwise drive opacity
            // with a TimelineView. Either way the rectangle is unblocked by
            // hit-testing so taps continue to land on the prompter.
            if reduceMotion {
                tallyShape(opacity: 1.0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    tallyShape(opacity: pulseOpacity(at: context.date))
                }
            }
        }
    }

    @ViewBuilder
    private func tallyShape(opacity: Double) -> some View {
        Rectangle()
            .strokeBorder(Self.tallyRed, lineWidth: thickness)
            .opacity(opacity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true) // VO has its own state announcements
    }

    /// Sine-wave opacity in [0.6, 1.0] over a 2s period. Phase locked to
    /// `Date.now.timeIntervalSinceReferenceDate` so the pulse keeps phase
    /// across redraws and across navigations into and out of the prompter.
    private func pulseOpacity(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        let phase = (t / pulsePeriod).truncatingRemainder(dividingBy: 1.0)
        // sin(0) = 0 → start mid-amplitude; map sin's [-1, 1] onto [0.6, 1.0].
        let raw = sin(phase * 2 * .pi)
        return 0.8 + 0.2 * raw
    }
}

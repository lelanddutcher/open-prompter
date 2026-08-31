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
//  - Shape: a `RoundedRectangle` whose corner radius matches the device's
//    display corner radius (queried via the private `_displayCornerRadius`
//    selector — widely used in shipping apps and tolerated by App Review).
//    Falls back to 0 on devices with square corners (iPhone SE 2/3, iPad).
//    The dogfood report flagged that a hard `Rectangle` cut across the
//    rounded screen corners awkwardly.
//
//  This ships in Feature 1 even though recording itself is Feature 2; the
//  Labs settings adds a debug toggle to flip it on for design validation
//  until Feature 2 wires the real `RecordingState.isRecording` flow.
//

import SwiftUI
import UIKit

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

    /// Corner radius for the tally border.
    ///
    /// `UIScreen.main` is the DISPLAY, not this app's window. As a "Designed
    /// for iPad" app on Apple Silicon this runs in a freely resizable window
    /// whose corners have nothing to do with the Mac's display radius, and
    /// `UIScreen.main` is deprecated for multi-scene besides. Use the screen
    /// backing the active window scene; fall back to a square corner when
    /// there is no scene rather than inheriting a phone-shaped radius.
    static var hostCornerRadius: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let screen = scene?.screen else { return 0 }
        return screen.displayCornerRadius
    }

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
        // Match the screen's rounded corners. Stroke is centered on the
        // path, so the visible inner edge sits at `cornerRadius - thickness/2`
        // — close enough to feel like the device border at 4pt thickness.
        // On square-corner devices `cornerRadius` is 0 and the rounded
        // rectangle collapses back to a hard rectangle.
        RoundedRectangle(cornerRadius: Self.hostCornerRadius, style: .continuous)
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

extension UIScreen {
    /// The corner radius of the device's display, in points. Returns 0 on
    /// devices with square corners (iPhone SE 2/3, iPad).
    ///
    /// Queries the private `_displayCornerRadius` (and a fallback alias
    /// without the underscore) via KVC. This API is widely used in shipped
    /// apps (it's the standard technique for matching the device-frame
    /// outline) and is tolerated by App Review. If Apple ever removes the
    /// selector the `responds(to:)` guard returns nil and we fall back to 0.
    var displayCornerRadius: CGFloat {
        let key = ["_displayCornerRadius", "displayCornerRadius"].first {
            responds(to: NSSelectorFromString($0))
        }
        return key.flatMap { value(forKey: $0) as? CGFloat } ?? 0
    }
}

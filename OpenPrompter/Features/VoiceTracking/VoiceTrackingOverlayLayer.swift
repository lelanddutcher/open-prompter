//
//  VoiceTrackingOverlayLayer.swift
//  OpenPrompter
//
//  Voice-tracking on-screen UI surfaces, factored into a dedicated
//  View struct so its type-checking lives outside `TeleprompterView`'s
//  body budget (the consolidated overlay tipped that body's body
//  expression past Swift's type-check ceiling otherwise).
//
//  Two pieces compose here, both gated on `tracker.isActive`:
//
//  - **Audio meter HUD** (left edge): an 8-segment vertical bar fed
//    by `VoiceTracker.audioLevel`, plus the last few recognized words
//    and a RESET button.
//  - **Reading-box indicator** (full width): a tinted band between
//    two draggable horizontal edges (TOP + BOT). The velocity
//    controller treats the band as a deadzone — matched word inside
//    → no scroll correction; above top → slow/reverse; below bottom
//    → speed up. Two zones to dial in feel (position + tolerance).
//

import SwiftUI

struct VoiceTrackingOverlayLayer: View {
    let tracker: VoiceTracker
    @Binding var boxTopFraction: Double
    @Binding var boxBottomFraction: Double

    var body: some View {
        ZStack {
            VoiceTrackingHUDView(tracker: tracker)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            VoiceReadingBoxIndicatorView(
                isActive: tracker.isActive,
                topFraction: $boxTopFraction,
                bottomFraction: $boxBottomFraction
            )
        }
        .allowsHitTesting(tracker.isActive)
    }
}

// MARK: - ViewModifier wrapper

/// Bundles voice-tracking modifiers (overlay + cursor-advance change
/// listener) into a single `ViewModifier` so applying them to
/// `TeleprompterView.body` adds only ONE entry to its modifier chain.
/// Without this, the body's view-tree complexity exceeded SwiftUI's
/// type-check budget on Swift 5.10.
struct VoiceTrackingChrome: ViewModifier {
    /// Bundle of values that, when ANY changes, should re-aim the
    /// lerp target. Passed as a value-typed `Equatable` so SwiftUI's
    /// `.onChange` reliably fires (observing the @Binding's wrapped
    /// value directly was unreliable on device — drag updates didn't
    /// always re-render the target until voice was toggled off/on).
    struct LayoutKey: Equatable {
        let fontSize: Double
        /// Included so a font-size change re-fires onChange AFTER the
        /// GeometryReader has measured the new content height. Without
        /// this, the recompute used a stale contentHeight and the
        /// scroll target landed at the wrong offset.
        let contentHeight: CGFloat
        /// Included for the same reason — viewport changes (e.g. on
        /// rotation, keyboard) re-aim the deadzone.
        let viewportHeight: CGFloat
        let boxTopFraction: Double
        let boxBottomFraction: Double
    }

    let tracker: VoiceTracker
    @Binding var boxTopFraction: Double
    @Binding var boxBottomFraction: Double
    let onCursorChange: () -> Void
    let layoutKey: LayoutKey

    func body(content: Content) -> some View {
        content
            .overlay {
                VoiceTrackingOverlayLayer(
                    tracker: tracker,
                    boxTopFraction: $boxTopFraction,
                    boxBottomFraction: $boxBottomFraction
                )
            }
            .onChange(of: tracker.lastMatch?.cursorIndex) { _, _ in
                onCursorChange()
            }
            .onChange(of: layoutKey) { _, _ in
                onCursorChange()
            }
    }
}

// MARK: - HUD

private struct VoiceTrackingHUDView: View {
    let tracker: VoiceTracker

    var body: some View {
        if tracker.isActive {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let level = CGFloat(tracker.audioLevel)
        let activeSegments = max(1, Int(level * 8))
        VStack(alignment: .leading, spacing: 6) {
            audioMeter(activeSegments: activeSegments)
            Text("VOICE")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(Theme.green)
            recognizedWordsView
            resetButton
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding(.leading, 6)
    }

    private func audioMeter(activeSegments: Int) -> some View {
        VStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { i in
                let segIndex = 8 - i
                let isLit = segIndex <= activeSegments
                Rectangle()
                    .fill(isLit ? Theme.green : Theme.surface2)
                    .frame(width: 6, height: 8)
                    .opacity(isLit ? 1.0 : 0.35)
            }
        }
        .animation(.linear(duration: 0.05), value: activeSegments)
    }

    @ViewBuilder
    private var recognizedWordsView: some View {
        let recent = tracker.lastRecognizedWords.suffix(3).joined(separator: " ")
        if !recent.isEmpty {
            Text(recent)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.muted)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: 90, alignment: .leading)
        }
    }

    private var resetButton: some View {
        Button(action: { tracker.resetCursor() }) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.uturn.up")
                    .font(.system(size: 8, weight: .bold))
                Text("RESET")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .tracking(0.5)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Theme.surface2, in: Capsule())
            .foregroundStyle(Theme.fg)
        }
    }
}

// MARK: - Reading-box indicator

/// Two-handle band (top edge + bottom edge) marking where matched
/// words should land on screen. The velocity controller treats
/// the band as a deadzone — matched word inside the band → no
/// scroll correction; above the top → slow down; below the bottom
/// → speed up. Two zones to dial in feel (position + tolerance)
/// instead of a single line.
private struct VoiceReadingBoxIndicatorView: View {
    let isActive: Bool
    @Binding var topFraction: Double
    @Binding var bottomFraction: Double

    var body: some View {
        if isActive {
            GeometryReader { geo in
                content(geo: geo)
            }
            .allowsHitTesting(true)
        }
    }

    private func content(geo: GeometryProxy) -> some View {
        let topY = geo.size.height * CGFloat(topFraction)
        let bottomY = geo.size.height * CGFloat(bottomFraction)
        return ZStack(alignment: .topLeading) {
            Color.clear
            // Tinted band between top + bottom — visualizes the
            // deadzone for the velocity controller.
            Rectangle()
                .fill(Theme.green.opacity(0.07))
                .frame(height: max(0, bottomY - topY))
                .padding(.leading, geo.size.width * 0.55)
                .padding(.trailing, 16)
                .offset(y: topY)
            // Edge lines — top + bottom.
            Rectangle()
                .fill(Theme.green.opacity(0.35))
                .frame(height: 1)
                .padding(.leading, geo.size.width * 0.55)
                .padding(.trailing, 60)
                .offset(y: topY)
            Rectangle()
                .fill(Theme.green.opacity(0.35))
                .frame(height: 1)
                .padding(.leading, geo.size.width * 0.55)
                .padding(.trailing, 60)
                .offset(y: bottomY)
            // Handles for each edge.
            handle(label: "TOP", geo: geo, y: topY, isTop: true)
            handle(label: "BOT", geo: geo, y: bottomY, isTop: false)
        }
    }

    private func handle(label: String, geo: GeometryProxy, y: CGFloat, isTop: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .bold))
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.5)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().stroke(Theme.green.opacity(0.5), lineWidth: 1))
        .foregroundStyle(Theme.green)
        .offset(x: geo.size.width - 64, y: y - 12)
        .gesture(
            DragGesture()
                .onChanged { value in
                    let height = geo.size.height
                    let raw = max(20, min(height - 20, value.location.y))
                    let newFrac = Double(raw / height)
                    if isTop {
                        // Top can't go below bottom - 0.05 of viewport.
                        topFraction = min(newFrac, bottomFraction - 0.05)
                    } else {
                        // Bottom can't go above top + 0.05.
                        bottomFraction = max(newFrac, topFraction + 0.05)
                    }
                }
        )
    }
}

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
        // The audio-meter HUD moved into `PrompterControlsView` as a
        // horizontal strip (see VoiceTrackingHUDStrip). This overlay
        // now only paints the reading-box indicator on the prompter.
        VoiceReadingBoxIndicatorView(
            isActive: tracker.isActive,
            topFraction: $boxTopFraction,
            bottomFraction: $boxBottomFraction
        )
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
        /// Font-size change re-fires onChange AFTER the GeometryReader
        /// has measured the new content height. Without this, the
        /// recompute used a stale contentHeight and the scroll target
        /// landed at the wrong offset.
        let contentHeight: CGFloat
        /// Same reasoning — viewport changes (rotation, keyboard)
        /// re-aim the target.
        let viewportHeight: CGFloat
        // Note: box top/bottom fractions are deliberately NOT in this
        // key. Dragging the box should NOT trigger scroll — that was
        // the "phantom movement" reported on device. The box's bottom
        // edge is read at the next genuine cursor advance instead.
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

// MARK: - HUD strip

/// Horizontal status strip rendered ABOVE the prompter controls
/// (inside `PrompterControlsView`). No background blur — sits
/// directly on the prompter backdrop. Auto-hides with the rest of
/// the bottom chrome when focus mode is on (because it's part of
/// the bottom VStack, which already inherits the focus opacity).
struct VoiceTrackingHUDStrip: View {
    let tracker: VoiceTracker

    var body: some View {
        if tracker.isActive {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let level = CGFloat(tracker.audioLevel)
        let activeSegments = max(0, Int(level * 8))
        HStack(spacing: 8) {
            // Horizontal level meter — 8 segments fill left-to-right
            // as audio level rises.
            HStack(spacing: 2) {
                ForEach(0..<8, id: \.self) { i in
                    let isLit = i < activeSegments
                    Rectangle()
                        .fill(isLit ? Theme.green : Theme.surface2)
                        .frame(width: 4, height: 10)
                        .opacity(isLit ? 1.0 : 0.4)
                }
            }
            .animation(.linear(duration: 0.05), value: activeSegments)
            // Last-recognized-words preview, monospaced so the strip
            // doesn't reflow as recognition delivers new content.
            let recent = tracker.lastRecognizedWords.suffix(4).joined(separator: " ")
            Text(recent.isEmpty ? "listening…" : recent)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(recent.isEmpty ? Theme.dim : Theme.muted)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            // RESET — drops the cursor to start of script.
            Button(action: { tracker.resetCursor() }) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.uturn.up")
                        .font(.system(size: 9, weight: .bold))
                    Text("RESET")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.5)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .foregroundStyle(Theme.green)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
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
